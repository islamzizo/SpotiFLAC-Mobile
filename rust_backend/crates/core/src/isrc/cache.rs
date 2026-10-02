use crate::matching::uppercase;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, TryLockError, Weak};
use std::time::{Duration, Instant};

type Check<'a> = &'a (dyn Fn() -> Result<(), String> + Sync);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileStamp {
    pub path: String,
    pub size: u64,
    pub modified_ns: i128,
    pub directory: bool,
}

/// The native owner supplies filesystem access. A cache hit never grants access
/// to a path: adapters must validate directory authority before each operation.
pub trait IndexFiles: Sync {
    /// Return entries in lexical depth-first walk order, preserving directory
    /// boundaries rather than sorting the complete path strings afterward.
    fn list(&self, directory: &str, check: Check<'_>) -> Result<Vec<FileStamp>, String>;
    fn read(&self, path: &str, check: Check<'_>) -> Result<String, String>;
    fn stat(&self, path: &str) -> Result<Option<FileStamp>, String>;
}

#[derive(Clone)]
struct FileEntry {
    stamp: FileStamp,
    isrc: String,
}

struct Index {
    entries: BTreeMap<String, String>,
    files: BTreeMap<String, FileEntry>,
    built_at: Instant,
}

pub struct IndexCache {
    indexes: Mutex<BTreeMap<String, Arc<Mutex<Index>>>>,
    builders: Mutex<BTreeMap<String, Weak<Mutex<()>>>>,
    ttl: Duration,
}

impl Default for IndexCache {
    fn default() -> Self {
        Self::with_ttl(Duration::from_secs(5 * 60))
    }
}

impl IndexCache {
    pub fn with_ttl(ttl: Duration) -> Self {
        Self {
            indexes: Mutex::default(),
            builders: Mutex::default(),
            ttl,
        }
    }

    fn cached(&self, directory: &str) -> Option<Arc<Mutex<Index>>> {
        self.indexes
            .lock()
            .expect("ISRC cache lock")
            .get(directory)
            .cloned()
    }

    fn fresh(&self, directory: &str) -> Option<Arc<Mutex<Index>>> {
        self.cached(directory)
            .filter(|index| index.lock().expect("ISRC index lock").built_at.elapsed() < self.ttl)
    }

    fn index(
        &self,
        directory: &str,
        files: &dyn IndexFiles,
        force: bool,
        check: Check<'_>,
    ) -> Result<Arc<Mutex<Index>>, String> {
        check()?;
        if !force && let Some(index) = self.fresh(directory) {
            return Ok(index);
        }
        let builder = {
            let mut builders = self.builders.lock().expect("ISRC builders lock");
            let entry = builders.entry(directory.into()).or_default();
            entry.upgrade().unwrap_or_else(|| {
                let lock = Arc::new(Mutex::new(()));
                *entry = Arc::downgrade(&lock);
                lock
            })
        };
        let _building = wait_for_builder(&builder, check)?;
        if !force && let Some(index) = self.fresh(directory) {
            return Ok(index);
        }
        let previous = self
            .cached(directory)
            .map(|index| index.lock().expect("ISRC index lock").files.clone())
            .unwrap_or_default();
        let mut index = Index {
            entries: BTreeMap::new(),
            files: BTreeMap::new(),
            built_at: Instant::now(),
        };
        let mut changed = Vec::new();
        if !directory.is_empty() {
            let listed = files.list(directory, check)?;
            for stamp in listed {
                check()?;
                if stamp.directory || !super::supported(&stamp.path) {
                    continue;
                }
                if let Some(entry) = previous.get(&stamp.path)
                    && entry.stamp == stamp
                {
                    if !entry.isrc.is_empty() {
                        index.entries.insert(entry.isrc.clone(), stamp.path.clone());
                    }
                    index.files.insert(stamp.path.clone(), entry.clone());
                } else {
                    changed.push(stamp);
                }
            }
        }
        let next = AtomicUsize::new(0);
        let values = Mutex::new(vec![String::new(); changed.len()]);
        std::thread::scope(|scope| {
            let handles = (0..changed.len().min(4))
                .map(|_| {
                    scope.spawn(|| {
                        loop {
                            check()?;
                            let position = next.fetch_add(1, Ordering::Relaxed);
                            let Some(stamp) = changed.get(position) else {
                                break;
                            };
                            let isrc = uppercase(&files.read(&stamp.path, check)?);
                            values.lock().expect("ISRC parse results lock")[position] = isrc;
                        }
                        Ok::<_, String>(())
                    })
                })
                .collect::<Vec<_>>();
            for handle in handles {
                handle
                    .join()
                    .map_err(|_| "ISRC reader worker panicked".to_owned())??;
            }
            Ok::<_, String>(())
        })?;
        // Changed files are applied after reused entries, in walk order, just
        // as Go does after joining its four parsing workers.
        for (stamp, isrc) in changed
            .into_iter()
            .zip(values.into_inner().expect("ISRC parse results lock"))
        {
            check()?;
            if !isrc.is_empty() {
                index.entries.insert(isrc.clone(), stamp.path.clone());
            }
            index
                .files
                .insert(stamp.path.clone(), FileEntry { stamp, isrc });
        }
        check()?;
        let index = Arc::new(Mutex::new(index));
        if !directory.is_empty() {
            self.indexes
                .lock()
                .expect("ISRC cache lock")
                .insert(directory.into(), Arc::clone(&index));
        }
        Ok(index)
    }

    pub fn check(
        &self,
        directory: &str,
        isrc: &str,
        files: &dyn IndexFiles,
        check: Check<'_>,
    ) -> Result<String, String> {
        check()?;
        if directory.is_empty() || isrc.is_empty() {
            return Ok(String::new());
        }
        let index = self.index(directory, files, false, check)?;
        let key = uppercase(isrc);
        let path = index
            .lock()
            .expect("ISRC index lock")
            .entries
            .get(&key)
            .cloned();
        let Some(path) = path else {
            return Ok(String::new());
        };
        check()?;
        let exists = files
            .stat(&path)?
            .is_some_and(|stamp| !stamp.directory && stamp.size > 0);
        check()?;
        if exists {
            Ok(path)
        } else {
            index.lock().expect("ISRC index lock").entries.remove(&key);
            Ok(String::new())
        }
    }

    pub fn add(
        &self,
        directory: &str,
        isrc: &str,
        path: &str,
        files: &dyn IndexFiles,
        check: Check<'_>,
    ) -> Result<(), String> {
        check()?;
        if directory.is_empty() || isrc.is_empty() || path.is_empty() {
            return Ok(());
        }
        if let Some(index) = self.cached(directory) {
            let stamp = files.stat(path)?;
            check()?;
            let mut index = index.lock().expect("ISRC index lock");
            let isrc = uppercase(isrc);
            index.entries.insert(isrc.clone(), path.into());
            if let Some(stamp) = stamp {
                index.files.insert(path.into(), FileEntry { stamp, isrc });
            }
            index.built_at = Instant::now();
        }
        Ok(())
    }

    pub fn invalidate(&self, directory: &str) {
        self.indexes
            .lock()
            .expect("ISRC cache lock")
            .remove(directory);
    }

    pub fn clear(&self) {
        self.indexes.lock().expect("ISRC cache lock").clear();
    }
}

fn wait_for_builder<'a>(
    builder: &'a Mutex<()>,
    check: Check<'_>,
) -> Result<MutexGuard<'a, ()>, String> {
    loop {
        check()?;
        match builder.try_lock() {
            Ok(guard) => return Ok(guard),
            Err(TryLockError::Poisoned(error)) => return Ok(error.into_inner()),
            Err(TryLockError::WouldBlock) => std::thread::sleep(Duration::from_millis(5)),
        }
    }
}
