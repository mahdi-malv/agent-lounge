package wtf.mahdi.agentloungecompanion.net

import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.TimeUnit

sealed interface SocketEvent {
    /** Socket is open. The send functions return false when the data could not be queued. */
    class Opened(val sendText: (String) -> Boolean, val sendBinary: (ByteArray) -> Boolean) : SocketEvent
    data class Text(val text: String) : SocketEvent
    class Binary(val bytes: ByteArray) : SocketEvent
    /** Last event. [reason] is for the UI and logs. */
    data class Ended(val reason: String) : SocketEvent
}

/** WebSocket sessions to the Mac (`ws://` on the local network; the payload is encrypted, see `PhoneCrypto`). */
class LoungeSockets(
    private val client: OkHttpClient = defaultClient(),
) {
    /**
     * Opens a socket, sends [firstMessage] (clear text) when open, and emits events until the socket
     * ends. The flow completes after [SocketEvent.Ended]. Cancel the collector to close the socket.
     */
    fun open(host: String, port: Int, firstMessage: String): Flow<SocketEvent> = callbackFlow {
        val request = Request.Builder().url(url(host, port)).build()
        val socket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.send(firstMessage)
                trySend(
                    SocketEvent.Opened(
                        sendText = { webSocket.send(it) },
                        sendBinary = { webSocket.send(it.toByteString()) },
                    ),
                )
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                trySend(SocketEvent.Text(text))
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                trySend(SocketEvent.Binary(bytes.toByteArray()))
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(NORMAL_CLOSURE, null)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                trySend(SocketEvent.Ended("Closed by the Mac"))
                close()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                trySend(SocketEvent.Ended(t.message ?: t.javaClass.simpleName))
                close()
            }
        })
        awaitClose { socket.cancel() }
    }

    companion object {
        private const val NORMAL_CLOSURE = 1000

        fun url(host: String, port: Int): String {
            val literal = if (host.contains(':') && !host.startsWith("[")) "[$host]" else host
            return "ws://$literal:$port/"
        }

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.SECONDS)
            // Finds a dead Mac (sleep, Wi-Fi change) within about 40 s. The Mac answers pings itself.
            .pingInterval(20, TimeUnit.SECONDS)
            .build()
    }
}
