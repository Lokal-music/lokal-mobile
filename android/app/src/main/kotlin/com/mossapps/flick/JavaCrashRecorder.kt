package com.mossapps.flick

import android.content.Context
import android.os.Process

/**
 * Recover Java/Kotlin uncaught exception stacks on the next launch.
 * No exception messages, user paths, network URLs or raw environment data
 * are exported; just exception type and method/line frames.
 */
internal object JavaCrashRecorder {
    private const val PREFS = "crash_diagnostics"
    private const val KEY = "pending_java_crash"
    @Volatile private var installed = false

    fun install(context: Context) {
        synchronized(this) {
            if (installed) return
            installed = true
            val appContext = context.applicationContext
            val previous = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler { thread, error ->
                try {
                    val lines = format(error)
                    appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                        .edit().putString(KEY, lines).commit()
                } catch (_: Throwable) {
                    // Do not prevent Android's existing crash handler from
                    // reporting or terminating the failing process.
                } finally {
                    if (previous != null) {
                        previous.uncaughtException(thread, error)
                    } else {
                        Process.killProcess(Process.myPid())
                    }
                }
            }
        }
    }

    fun consume(context: Context): String? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val value = prefs.getString(KEY, null)
        if (value != null) prefs.edit().remove(KEY).commit()
        return value
    }

    internal fun format(error: Throwable): String {
        val name = error.javaClass.simpleName.take(100)
        val frames = error.stackTrace.take(18).mapIndexed { index, frame ->
            // StackTraceElement.fileName can be an arbitrary user path; omit it.
            "#$index ${frame.className.take(110)}.${frame.methodName.take(100)}:${frame.lineNumber}"
        }
        return ("type=$name\\n" + frames.joinToString("\\n")).take(2600)
    }
}
