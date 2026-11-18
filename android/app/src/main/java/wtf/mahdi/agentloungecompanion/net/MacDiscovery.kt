package wtf.mahdi.agentloungecompanion.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.withTimeoutOrNull
import wtf.mahdi.agentloungecompanion.core.MacFinder
import wtf.mahdi.agentloungecompanion.protocol.LoungeProtocol
import java.net.Inet4Address
import java.net.InetAddress
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** A Mac found with mDNS (`_agentlounge._tcp`). */
data class DiscoveredMac(
    val name: String,
    /** Bonjour TXT `id`, same as `serverId` in the protocol. Empty when missing. */
    val serverId: String,
    val host: String,
    val port: Int,
)

/** mDNS discovery with [NsdManager]. On Android 17+ this needs ACCESS_LOCAL_NETWORK. */
class MacDiscovery(context: Context) : MacFinder {
    private val nsd = context.applicationContext.getSystemService(NsdManager::class.java)
    /** Never shut down: NsdManager can still post callbacks to it after unregistering. */
    private val executor = Executors.newSingleThreadExecutor()

    /** Current list of resolved Macs. Discovery runs while the flow is collected. */
    fun discover(): Flow<List<DiscoveredMac>> = callbackFlow {
        val found = linkedMapOf<String, DiscoveredMac>()
        val resolver = Resolver(nsd, executor) { name, mac ->
            // Called from NSD threads.
            val list = synchronized(found) {
                if (mac == null) found.remove(name) else found[name] = mac
                found.values.toList()
            }
            trySend(list)
        }
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "Discovery failed: $errorCode")
                close(IllegalStateException("Discovery failed ($errorCode)"))
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
            override fun onServiceFound(info: NsdServiceInfo) {
                resolver.resolve(info)
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                resolver.lost(info.serviceName)
            }
        }
        trySend(emptyList())
        nsd.discoverServices(LoungeProtocol.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        awaitClose {
            runCatching { nsd.stopServiceDiscovery(listener) }
            resolver.stop()
        }
    }

    /** Address of the Mac with this server id, or null after [timeoutMillis]. */
    override suspend fun find(serverId: String, timeoutMillis: Long): DiscoveredMac? = withTimeoutOrNull(timeoutMillis) {
        discover().mapNotNull { list -> list.firstOrNull { it.serverId == serverId } }.first()
    }

    private companion object {
        const val TAG = "MacDiscovery"
    }
}

/**
 * Resolves found services. API 34+: one live callback per service (follows address changes).
 * Older: `resolveService`, one at a time (the platform refuses parallel resolves).
 */
private class Resolver(
    private val nsd: NsdManager,
    private val executor: Executor,
    private val onUpdate: (name: String, mac: DiscoveredMac?) -> Unit,
) {
    private val callbacks = mutableMapOf<String, Any>()
    private val queue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    @Volatile private var stopped = false

    fun resolve(info: NsdServiceInfo): Unit = synchronized(this) {
        if (stopped || callbacks.containsKey(info.serviceName)) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val callback = object : NsdManager.ServiceInfoCallback {
                override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) = Unit
                override fun onServiceUpdated(serviceInfo: NsdServiceInfo) {
                    if (stopped) return
                    serviceInfo.toMac()?.let { onUpdate(serviceInfo.serviceName, it) }
                }
                override fun onServiceLost() = onUpdate(info.serviceName, null)
                override fun onServiceInfoCallbackUnregistered() = Unit
            }
            callbacks[info.serviceName] = callback
            runCatching { nsd.registerServiceInfoCallback(info, executor, callback) }
        } else {
            callbacks[info.serviceName] = Unit
            queue.addLast(info)
            next()
        }
    }

    fun lost(name: String): Unit = synchronized(this) {
        val callback = callbacks.remove(name)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && callback is NsdManager.ServiceInfoCallback) {
            runCatching { nsd.unregisterServiceInfoCallback(callback) }
        }
        onUpdate(name, null)
    }

    fun stop(): Unit = synchronized(this) {
        stopped = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            callbacks.values.filterIsInstance<NsdManager.ServiceInfoCallback>()
                .forEach { runCatching { nsd.unregisterServiceInfoCallback(it) } }
        }
        callbacks.clear()
        queue.clear()
    }

    @Suppress("DEPRECATION")
    private fun next() {
        if (resolving || stopped) return
        val info = queue.removeFirstOrNull() ?: return
        resolving = true
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = done()
            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                serviceInfo.toMac()?.let { onUpdate(serviceInfo.serviceName, it) }
                done()
            }
        })
    }

    private fun done(): Unit = synchronized(this) {
        resolving = false
        next()
    }
}

private fun NsdServiceInfo.toMac(): DiscoveredMac? {
    val addresses: List<InetAddress> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
        hostAddresses
    } else {
        @Suppress("DEPRECATION")
        listOfNotNull(host)
    }
    // IPv4 first: link-local IPv6 needs a scope id, which URLs handle badly.
    val address = addresses.firstOrNull { it is Inet4Address } ?: addresses.firstOrNull() ?: return null
    val id = attributes["id"]?.decodeToString().orEmpty()
    return DiscoveredMac(name = serviceName, serverId = id, host = address.hostAddress ?: return null, port = port)
}
