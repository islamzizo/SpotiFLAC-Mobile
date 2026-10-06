package com.zarz.spotiflac

import com.spotiflac.backend.CancellationDomain
import com.spotiflac.backend.CancellationRegistry
import com.spotiflac.backend.RequestLease
import org.json.JSONObject

// Independent of extension initialization: palette/metadata jobs can start
// while app initialization is still running. Acquire before queuing on IO, so
// a following channel cancellation also reaches work that has not started.
internal object NativeDataJobs {
    private val registry = CancellationRegistry(CancellationDomain.EXTENSION_REQUEST)
    private val active = mutableMapOf<String, MutableList<RequestLease>>()

    @Synchronized
    fun acquire(id: String): RequestLease {
        val lease = registry.acquire(id)
        active.getOrPut(id) { mutableListOf() }.add(lease)
        return lease
    }

    @Synchronized
    fun cancel(id: String) {
        // The shared extension registry supports pre-cancel sentinels. Data
        // jobs are acquired in channel order instead and must not retain them.
        if (active[id]?.isNotEmpty() == true) registry.cancel(id)
    }

    @Synchronized
    fun release(id: String, lease: RequestLease) {
        val leases = active[id] ?: return
        val index = leases.indexOfFirst { it === lease }
        if (index < 0) return
        leases.removeAt(index)
        try {
            lease.release()
        } finally {
            try { lease.close() }
            finally { if (leases.isEmpty()) active.remove(id) }
        }
    }
}

internal fun MainActivity.runNativeDataJobPlatform(arguments: Any?, lease: RequestLease): Any {
    val args = arguments as? Map<*, *> ?: error("Missing data job arguments")
    val request = JSONObject(args["request_json"] as? String ?: error("Missing data job request"))
    val bytes = args["bytes"] as? ByteArray ?: byteArrayOf()
    return bridgeJsonResult(RustCoreBackend.runDataJob(request, bytes, lease))
}
