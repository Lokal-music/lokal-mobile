//! Cancellation boundary for local native requests, including work not yet
//! started by FRB's worker pool. Tokens must be captured before FFI submission.
//! The atomic invalidator never waits on engine initialization or network I/O.

use std::cell::Cell;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;

const RETIRED: &str = "AUDIO_LOCAL_REQUEST_RETIRED";
const UNCERTAIN: &str = "AUDIO_LOCAL_CLEANUP_UNCONFIRMED";

pub(crate) struct RequestFence {
    generation: AtomicU64,
    exhausted: AtomicBool,
    cleanup_uncertain: AtomicBool,
    mutation: Mutex<()>,
}

impl RequestFence {
    pub const fn new() -> Self {
        Self {
            generation: AtomicU64::new(0),
            exhausted: AtomicBool::new(false),
            cleanup_uncertain: AtomicBool::new(false),
            mutation: Mutex::new(()),
        }
    }

    pub fn invalidate(&self) -> Result<u64, String> {
        match self
            .generation
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |old| {
                old.checked_add(1)
            }) {
            Ok(old) => Ok(old + 1),
            Err(_) => {
                self.exhausted.store(true, Ordering::Release);
                Err(format!("{RETIRED}: generation exhausted; restart the app"))
            }
        }
    }

    pub fn generation(&self) -> Result<u64, String> {
        self.require_healthy()?;
        if self.exhausted.load(Ordering::Acquire) {
            return Err(format!("{RETIRED}: generation exhausted; restart the app"));
        }
        Ok(self.generation.load(Ordering::Acquire))
    }

    pub fn check(&self, expected: Option<u64>) -> Result<(), String> {
        // Existing unscoped callers on other platforms retain their behavior.
        if let Some(expected) = expected {
            self.require_healthy()?;
            if self.exhausted.load(Ordering::Acquire)
                || self.generation.load(Ordering::Acquire) != expected
            {
                return Err(format!("{RETIRED}: local playback request cancelled"));
            }
        }
        Ok(())
    }

    pub fn require_healthy(&self) -> Result<(), String> {
        if self.cleanup_uncertain.load(Ordering::Acquire) {
            return Err(format!(
                "{UNCERTAIN}: restart the app before creating local output"
            ));
        }
        Ok(())
    }

    /// Small configuration writes, not probes/decoding/engine initialization.
    /// Validate AFTER taking this lock so a queued old writer cannot run after
    /// reset cleanup and overwrite the restored configuration.
    pub fn mutate<T>(
        &self,
        expected: Option<u64>,
        action: impl FnOnce() -> Result<T, String>,
    ) -> Result<T, String> {
        if expected.is_none() {
            return action();
        }
        let _guard = self
            .mutation
            .lock()
            .map_err(|_| "Local request mutation lock poisoned".to_string())?;
        self.check(expected)?;
        action()
    }

    /// After invalidation, drain writers that crossed the atomic boundary.
    /// Later stale writers fail their check. Do not hold this lock over I/O.
    pub fn drain(&self) -> Result<(), String> {
        drop(
            self.mutation
                .lock()
                .map_err(|_| "Local request mutation lock poisoned".to_string())?,
        );
        Ok(())
    }
}

pub(crate) static LOCAL_REQUESTS: RequestFence = RequestFence::new();

thread_local! {
    static EXPECTED: Cell<Option<u64>> = const { Cell::new(None) };
}

pub(crate) struct RequestScope {
    previous: Option<u64>,
}

impl RequestScope {
    pub fn enter(expected: Option<u64>) -> Result<Self, String> {
        let previous = current();
        #[cfg(target_os = "ios")]
        if expected.is_none() && previous.is_none() {
            return Err(format!(
                "{RETIRED}: an iPhone request requires a generation"
            ));
        }
        if previous.is_some() && expected.is_some() && previous != expected {
            return Err(format!(
                "{RETIRED}: a nested request cannot replace its generation"
            ));
        }
        let expected = expected.or(previous);
        LOCAL_REQUESTS.check(expected)?;
        EXPECTED.with(|slot| slot.set(expected));
        Ok(Self { previous })
    }
}

impl Drop for RequestScope {
    fn drop(&mut self) {
        EXPECTED.with(|slot| slot.set(self.previous));
    }
}

pub(crate) fn current() -> Option<u64> {
    EXPECTED.with(Cell::get)
}

pub(crate) fn check_current() -> Result<(), String> {
    LOCAL_REQUESTS.check(current())
}

pub(crate) fn mutate<T>(action: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    LOCAL_REQUESTS.mutate(current(), action)
}

pub(crate) fn cleanup_failed(error: String, expected: Option<u64>) -> String {
    if cfg!(target_os = "ios") || expected.is_some() {
        LOCAL_REQUESTS
            .cleanup_uncertain
            .store(true, Ordering::Release);
        format!("{UNCERTAIN}: {error}")
    } else {
        error
    }
}

// Called directly by the native iOS lifecycle observer, before dispatching the
// event to Dart. This also fences background work while the UI isolate is busy.
// No Flutter/Dart runtime, engine mutex, allocation or I/O is needed on success.
#[cfg(target_os = "ios")]
#[no_mangle]
pub extern "C" fn lokal_audio_invalidate_local_requests() -> u64 {
    LOCAL_REQUESTS.invalidate().unwrap_or(u64::MAX)
}

// Raw snapshot for the Swift event payload, including when cleanup is blocked.
// The checked Dart API remains authoritative for permission to create output.
#[cfg(target_os = "ios")]
#[no_mangle]
pub extern "C" fn lokal_audio_local_request_epoch() -> u64 {
    LOCAL_REQUESTS.generation.load(Ordering::Acquire)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{mpsc, Arc};
    use std::thread;
    use std::time::Duration;

    #[test]
    fn queued_request_keeps_the_token_captured_before_worker_execution() {
        let fence = Arc::new(RequestFence::new());
        let token = fence.invalidate().unwrap();
        let (start, ready) = mpsc::channel();
        let worker_fence = fence.clone();
        let worker = thread::spawn(move || {
            ready.recv_timeout(Duration::from_secs(2)).unwrap();
            worker_fence.check(Some(token))
        });
        fence.invalidate().unwrap();
        start.send(()).unwrap();
        assert!(worker.join().unwrap().unwrap_err().starts_with(RETIRED));
    }

    #[test]
    fn a_late_probe_cannot_authorize_creation_after_cleanup() {
        let fence = Arc::new(RequestFence::new());
        let token = fence.invalidate().unwrap();
        let (started, probe_started) = mpsc::channel();
        let (finish, probe_finished) = mpsc::channel();
        let created = Arc::new(AtomicBool::new(false));
        let worker_fence = fence.clone();
        let worker_created = created.clone();
        let worker = thread::spawn(move || {
            worker_fence.check(Some(token))?;
            started.send(()).unwrap();
            probe_finished.recv_timeout(Duration::from_secs(2)).unwrap();
            worker_fence.check(Some(token))?;
            worker_created.store(true, Ordering::Release);
            Ok::<(), String>(())
        });
        probe_started.recv_timeout(Duration::from_secs(2)).unwrap();
        fence.invalidate().unwrap();
        fence.drain().unwrap();
        finish.send(()).unwrap();
        assert!(worker.join().unwrap().is_err());
        assert!(!created.load(Ordering::Acquire));
    }

    #[test]
    fn invalidation_is_nonblocking_but_cleanup_drains_crossing_writes() {
        let fence = Arc::new(RequestFence::new());
        let token = fence.invalidate().unwrap();
        let (started, writing) = mpsc::channel();
        let (finish, release) = mpsc::channel();
        let writer_fence = fence.clone();
        let writer = thread::spawn(move || {
            writer_fence.mutate(Some(token), || {
                started.send(()).unwrap();
                release.recv_timeout(Duration::from_secs(2)).unwrap();
                Ok(())
            })
        });
        writing.recv_timeout(Duration::from_secs(2)).unwrap();
        let next = fence.invalidate().unwrap(); // Returns while writer holds the lock.
        let (drained, observed) = mpsc::channel();
        let cleanup_fence = fence.clone();
        let cleanup = thread::spawn(move || {
            cleanup_fence.drain().unwrap();
            drained.send(()).unwrap();
        });
        assert!(observed.try_recv().is_err());
        finish.send(()).unwrap();
        writer.join().unwrap().unwrap();
        observed.recv_timeout(Duration::from_secs(2)).unwrap();
        cleanup.join().unwrap();
        let value = AtomicU64::new(0);
        fence
            .mutate(Some(next), || {
                value.store(9, Ordering::Release);
                Ok(())
            })
            .unwrap();
        assert!(fence
            .mutate(Some(token), || {
                value.store(1, Ordering::Release);
                Ok(())
            })
            .is_err());
        assert_eq!(value.load(Ordering::Acquire), 9);
    }

    #[test]
    fn exhaustion_fails_closed_without_wrapping_to_an_old_token() {
        let fence = RequestFence::new();
        fence.generation.store(u64::MAX, Ordering::Release);
        assert!(fence.invalidate().is_err());
        assert!(fence.check(Some(u64::MAX)).is_err());
        assert!(fence.check(Some(0)).is_err());
        // Cleanup and existing other-platform callers remain available.
        assert!(fence.check(None).is_ok());
        assert!(fence.drain().is_ok());
    }

    #[test]
    fn unconfirmed_cleanup_blocks_fresh_requests_and_epoch_readers() {
        let fence = RequestFence::new();
        let token = fence.invalidate().unwrap();
        fence.cleanup_uncertain.store(true, Ordering::Release);
        assert!(fence.generation().unwrap_err().starts_with(UNCERTAIN));
        assert!(fence.check(Some(token)).unwrap_err().starts_with(UNCERTAIN));
        // A newer token is not permission to create a replacement output.
        let newer = fence.invalidate().unwrap();
        assert!(fence.check(Some(newer)).is_err());
        assert!(fence.drain().is_ok());
    }

    #[test]
    fn nested_fallbacks_inherit_the_same_request_scope() {
        let token = LOCAL_REQUESTS.generation.load(Ordering::Acquire);
        assert_eq!(current(), None);
        let outer = RequestScope::enter(Some(token)).unwrap();
        {
            let _fallback = RequestScope::enter(None).unwrap();
            assert_eq!(current(), Some(token));
            assert!(RequestScope::enter(Some(token + 1)).is_err());
        }
        assert_eq!(current(), Some(token));
        drop(outer);
        assert_eq!(current(), None);
    }
}
