//! Shared OAuth state and one-time callback ownership for managed runtimes.

use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use zeroize::Zeroizing;

mod client;
pub use client::ExtensionAuth;

const SECOND: i128 = 1_000_000_000;
const PENDING_TTL: i128 = 180 * SECOND;

pub trait AuthClock: Send + Sync {
    fn now_nanos(&self) -> i128;
}

struct SystemClock;
impl AuthClock for SystemClock {
    fn now_nanos(&self) -> i128 {
        SystemTime::now().duration_since(UNIX_EPOCH).map_or_else(
            |error| -(error.duration().as_nanos() as i128),
            |time| time.as_nanos() as i128,
        )
    }
}

#[derive(Clone, Serialize)]
pub struct PendingAuthRequest {
    pub extension_id: String,
    pub auth_url: String,
    pub callback_url: String,
    #[serde(skip)]
    pub state: String,
    #[serde(skip)]
    pub created_at: i128,
}

#[derive(Default)]
struct Record {
    code: Zeroizing<String>,
    access_token: Zeroizing<String>,
    refresh_token: Zeroizing<String>,
    verifier: Zeroizing<String>,
    challenge: String,
    authenticated: bool,
    expires_at: Option<i128>,
}

#[derive(Default)]
struct State {
    records: BTreeMap<String, Record>,
    generations: BTreeMap<String, u64>,
    pending: BTreeMap<String, PendingAuthRequest>,
    owners: BTreeMap<String, String>,
    closed: bool,
}

pub struct AuthRegistry {
    state: Mutex<State>,
    clock: Arc<dyn AuthClock>,
}

impl Default for AuthRegistry {
    fn default() -> Self {
        Self::with_clock(Arc::new(SystemClock))
    }
}

impl AuthRegistry {
    pub fn with_clock(clock: Arc<dyn AuthClock>) -> Self {
        Self {
            state: Mutex::default(),
            clock,
        }
    }

    pub fn now(&self) -> i128 {
        self.clock.now_nanos()
    }

    fn edit<T>(&self, id: &str, edit: impl FnOnce(&mut Record) -> T) -> Result<T, String> {
        let mut state = self.state.lock().expect("auth registry lock");
        if state.closed {
            return Err("extension environment closed".into());
        }
        let generation = state.generations.entry(id.to_owned()).or_default();
        *generation = generation.wrapping_add(1);
        Ok(edit(state.records.entry(id.to_owned()).or_default()))
    }

    pub fn set_code(&self, id: &str, code: &str) -> Result<(), String> {
        self.edit(id, |record| record.code = Zeroizing::new(code.to_owned()))
    }

    pub fn code(&self, id: &str) -> Option<String> {
        self.state
            .lock()
            .expect("auth registry lock")
            .records
            .get(id)
            .filter(|record| !record.code.is_empty())
            .map(|record| record.code.to_string())
    }

    pub fn authenticated(&self, id: &str) -> bool {
        let now = self.now();
        self.state
            .lock()
            .expect("auth registry lock")
            .records
            .get(id)
            .is_some_and(|record| {
                record.authenticated && record.expires_at.is_none_or(|expires| now <= expires)
            })
    }

    pub fn tokens(&self, id: &str) -> Value {
        let state = self.state.lock().expect("auth registry lock");
        let Some(record) = state.records.get(id) else {
            return json!({});
        };
        let mut result = json!({"access_token":record.access_token.as_str(),"refresh_token":record.refresh_token.as_str(),"is_authenticated":record.authenticated});
        if let Some(expires) = record.expires_at {
            result["expires_at"] = json!(expires.div_euclid(SECOND) as i64);
            result["is_expired"] = json!(self.now() > expires);
        }
        result
    }

    pub fn clear(&self, id: &str) {
        let mut state = self.state.lock().expect("auth registry lock");
        if state.closed {
            return;
        }
        state.records.remove(id);
        let generation = state.generations.entry(id.to_owned()).or_default();
        *generation = generation.wrapping_add(1);
        Self::remove_pending(&mut state, id, self.now());
    }

    pub fn register_pending(&self, mut request: PendingAuthRequest) -> Result<(), String> {
        if request.extension_id.trim().is_empty() {
            return Err("extension id is required".into());
        }
        if request.state.is_empty() {
            request.state = callback_state()?;
        }
        if request.created_at == 0 {
            request.created_at = self.now();
        }
        let mut state = self.state.lock().expect("auth registry lock");
        if state.closed {
            return Err("extension environment closed".into());
        }
        if let Some(owner) = state
            .owners
            .get(&request.state)
            .filter(|owner| **owner != request.extension_id)
        {
            let same = state.pending.get(owner).is_some_and(|previous| {
                previous.state == request.state
                    && previous.auth_url == request.auth_url
                    && previous.callback_url == request.callback_url
                    && previous.created_at == request.created_at
            });
            if !same {
                return Err("callback state is already registered".into());
            }
        }
        if state
            .pending
            .get(&request.extension_id)
            .is_some_and(|previous| previous.state != request.state)
        {
            Self::remove_pending(&mut state, &request.extension_id, self.now());
        }
        state
            .owners
            .entry(request.state.clone())
            .or_insert_with(|| request.extension_id.clone());
        state.pending.insert(request.extension_id.clone(), request);
        Ok(())
    }

    fn remove_pending(state: &mut State, id: &str, now: i128) {
        let Some(request) = state.pending.remove(id) else {
            return;
        };
        if state
            .owners
            .get(&request.state)
            .is_none_or(|owner| owner != id)
        {
            return;
        }
        state.owners.remove(&request.state);
        if let Some((id, _)) = state.pending.iter().find(|(_, candidate)| {
            candidate.state == request.state && now - candidate.created_at < PENDING_TTL
        }) {
            state.owners.insert(request.state, id.clone());
        }
    }

    pub fn clear_pending(&self, id: &str) {
        Self::remove_pending(
            &mut self.state.lock().expect("auth registry lock"),
            id,
            self.now(),
        );
    }

    pub fn pending(&self, id: &str) -> Option<PendingAuthRequest> {
        let mut state = self.state.lock().expect("auth registry lock");
        if state
            .pending
            .get(id)
            .is_some_and(|request| self.now() - request.created_at >= PENDING_TTL)
        {
            Self::remove_pending(&mut state, id, self.now());
        }
        state.pending.get(id).cloned()
    }

    pub(crate) fn has_fresh_challenge(&self, id: &str) -> bool {
        self.pending(id).is_some_and(|request| {
            request.extension_id == id
                && !request.auth_url.trim().is_empty()
                && (0..PENDING_TTL).contains(&(self.now() - request.created_at))
        })
    }

    pub fn resolve_callback(&self, nonce: &str, consume: bool) -> Result<String, String> {
        let nonce = nonce.trim();
        if nonce.is_empty() {
            return Err("callback state is required".into());
        }
        let mut state = self.state.lock().expect("auth registry lock");
        let owner = state.owners.get(nonce).cloned();
        let valid = owner
            .as_ref()
            .and_then(|owner| state.pending.get(owner))
            .is_some_and(|request| {
                request.state == nonce && self.now() - request.created_at < PENDING_TTL
            });
        if !valid || consume {
            state.owners.remove(nonce);
            state.pending.retain(|_, request| request.state != nonce);
        }
        if valid {
            Ok(owner.expect("validated callback owner"))
        } else {
            Err("callback state is invalid, expired, or already used".into())
        }
    }

    pub fn shutdown(&self) {
        let mut state = self.state.lock().expect("auth registry lock");
        *state = State {
            closed: true,
            ..State::default()
        };
    }
}

pub fn callback_state() -> Result<String, String> {
    let mut random = Zeroizing::new([0_u8; 32]);
    getrandom::fill(random.as_mut())
        .map_err(|error| format!("generate callback state: {error}"))?;
    Ok(URL_SAFE_NO_PAD.encode(random.as_ref()))
}

pub fn pkce_verifier(length: usize) -> Result<String, String> {
    let length = length.clamp(43, 128);
    let mut random = Zeroizing::new(vec![0; length]);
    getrandom::fill(&mut random).map_err(|error| error.to_string())?;
    let mut verifier = URL_SAFE_NO_PAD.encode(random.as_slice());
    verifier.truncate(length);
    Ok(verifier)
}

pub fn pkce_challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier))
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Clock;
    impl AuthClock for Clock {
        fn now_nanos(&self) -> i128 {
            1000 * SECOND
        }
    }

    #[test]
    fn verification_requires_own_nonempty_challenge_between_zero_and_180_seconds_old() {
        for (age, url, expected) in [
            (-1, "https://example.test/verify", false),
            (0, "https://example.test/verify", true),
            (179, "https://example.test/verify", true),
            (180, "https://example.test/verify", false),
            (0, " \n", false),
        ] {
            let auth = AuthRegistry::with_clock(Arc::new(Clock));
            auth.register_pending(PendingAuthRequest {
                extension_id: "example.auth".into(),
                auth_url: url.into(),
                callback_url: "spotiflac://callback".into(),
                state: "state".into(),
                created_at: (1000 - age) * SECOND,
            })
            .unwrap();
            assert_eq!(auth.has_fresh_challenge("example.auth"), expected);
            assert!(!auth.has_fresh_challenge("example.other"));
        }
    }
}
