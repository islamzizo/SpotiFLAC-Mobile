//! Bounded, seekable metadata reads through the app's authenticated loopback
//! proxy. The native reader never receives NAS credentials or external URLs.
use base64::Engine;
use serde_json::Value;
use spotiflac_core::tags;
use spotiflac_network::{
    HttpRequest, NetworkService, NetworkSession, policy::NetworkPermissions, url::UrlParts,
};
use std::{
    collections::{BTreeMap, VecDeque},
    io::{self, Read, Seek, SeekFrom},
    sync::{Arc, OnceLock},
    time::{Duration, Instant},
};

const BLOCK: u64 = 256 * 1024;
const MAX_BYTES: usize = 16 * 1024 * 1024;
const MAX_REQUESTS: usize = 80;
const DEADLINE: Duration = Duration::from_secs(20);

pub(crate) fn read(
    url: &str,
    hint: &str,
    check: &dyn Fn() -> Result<(), String>,
) -> Result<Value, String> {
    let mut reader = RangeReader::new(url, check)?;
    let mut metadata = tags::read_file_metadata(&mut reader, hint, hint, check)?;
    let extension = tags::file_metadata_extension(hint, hint)?;
    if let Ok(cover) = tags::extract_cover(&mut reader, &extension[1..], check)
        && !cover.data.is_empty()
        && cover.data.len() <= 4 * 1024 * 1024
    {
        metadata["cover_base64"] = base64::engine::general_purpose::STANDARD
            .encode(cover.data)
            .into();
    }
    Ok(metadata)
}

struct RangeReader<'a> {
    url: String,
    session: NetworkSession,
    check: &'a dyn Fn() -> Result<(), String>,
    started: Instant,
    size: u64,
    position: u64,
    requests: usize,
    transferred: usize,
    blocks: VecDeque<(u64, Vec<u8>)>,
}

impl<'a> RangeReader<'a> {
    fn new(url: &str, check: &'a dyn Fn() -> Result<(), String>) -> Result<Self, String> {
        let parsed = UrlParts::parse(url).ok_or("invalid metadata URL")?;
        let token = parsed.path.strip_prefix(b"/").unwrap_or_default();
        if parsed.scheme != "http"
            || parsed.hostname != "127.0.0.1"
            || parsed.port.is_none()
            || parsed.has_credentials
            || !parsed.raw_query.is_empty()
            || !parsed.fragment.is_empty()
            || token.len() != 48
            || !token.iter().all(u8::is_ascii_hexdigit)
        {
            return Err("metadata URL must reference the local network proxy".into());
        }
        static NETWORK: OnceLock<Result<Arc<NetworkService>, String>> = OnceLock::new();
        let service = NETWORK
            .get_or_init(|| {
                let service = NetworkService::new().map_err(|e| e.to_string())?;
                service.set_allow_private_network(true);
                Ok(service)
            })
            .as_ref()
            .map_err(Clone::clone)?;
        let session = service
            .session(
                NetworkPermissions {
                    domains: vec!["127.0.0.1".into()],
                    allow_http: true,
                },
                DEADLINE,
            )
            .direct_media();
        let mut reader = Self {
            url: url.into(),
            session,
            check,
            started: Instant::now(),
            size: 0,
            position: 0,
            requests: 0,
            transferred: 0,
            blocks: VecDeque::new(),
        };
        reader.fetch(0).map_err(|e| e.to_string())?;
        Ok(reader)
    }

    fn check_budget(&self) -> io::Result<()> {
        (self.check)().map_err(io::Error::other)?;
        if self.started.elapsed() >= DEADLINE
            || self.requests >= MAX_REQUESTS
            || self.transferred >= MAX_BYTES
        {
            return Err(io::Error::other("network metadata read budget exceeded"));
        }
        Ok(())
    }

    fn fetch(&mut self, offset: u64) -> io::Result<()> {
        self.check_budget()?;
        self.requests += 1;
        let end = if self.size == 0 {
            offset + BLOCK - 1
        } else {
            (offset + BLOCK - 1).min(self.size - 1)
        };
        let request = HttpRequest {
            url: self.url.clone(),
            method: "GET".into(),
            body: String::new(),
            headers: BTreeMap::from([
                ("Range".into(), format!("bytes={offset}-{end}")),
                ("Accept-Encoding".into(), "identity".into()),
            ]),
            default_json: false,
            user_agent: "SpotiFLAC/NetworkMetadata".into(),
        };
        let mut stream = self
            .session
            .open_stream(request, DEADLINE, DEADLINE, || {
                (self.check)()?;
                if self.started.elapsed() >= DEADLINE {
                    Err("metadata timeout".into())
                } else {
                    Ok(())
                }
            })
            .map_err(io::Error::other)?;
        let header = |name: &str| {
            stream
                .response
                .headers
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case(name))
                .and_then(|(_, values)| values.first())
                .map(String::as_str)
        };
        let (size, length) = if stream.response.status == 206 {
            let range = header("content-range")
                .and_then(|s| s.strip_prefix("bytes "))
                .ok_or_else(|| io::Error::other("missing metadata range"))?;
            let (span, total) = range
                .split_once('/')
                .ok_or_else(|| io::Error::other("invalid range"))?;
            let (first, last) = span
                .split_once('-')
                .ok_or_else(|| io::Error::other("invalid range"))?;
            let first = first.parse::<u64>().map_err(io::Error::other)?;
            let last = last.parse::<u64>().map_err(io::Error::other)?;
            let size = total.parse::<u64>().map_err(io::Error::other)?;
            if first != offset || last < first || last > end || last >= size {
                return Err(io::Error::other(
                    "server returned an inconsistent metadata range",
                ));
            }
            (size, (last - first + 1) as usize)
        } else if stream.response.status == 200 && offset == 0 {
            let size = header("content-length")
                .and_then(|s| s.parse::<u64>().ok())
                .filter(|size| *size > 0 && *size <= BLOCK)
                .ok_or_else(|| io::Error::other("server must support byte ranges for metadata"))?;
            (size, size as usize)
        } else {
            return Err(io::Error::other("metadata byte range unavailable"));
        };
        if self.size != 0 && self.size != size {
            return Err(io::Error::other("remote file changed during metadata read"));
        }
        self.size = size;
        let mut bytes = vec![0; length];
        let mut count = 0;
        while count < length {
            self.check_budget()?;
            let n = stream
                .read(&mut bytes[count..], || (self.check)())
                .map_err(io::Error::other)?;
            if n == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "short metadata range",
                ));
            }
            count += n;
            self.transferred += n;
        }
        if self.blocks.len() >= 32 {
            self.blocks.pop_front();
        }
        self.blocks.push_back((offset, bytes));
        Ok(())
    }
}

impl Read for RangeReader<'_> {
    fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
        if output.is_empty() || self.position >= self.size {
            return Ok(0);
        }
        self.check_budget()?;
        let block = self.position / BLOCK * BLOCK;
        if !self.blocks.iter().any(|(start, _)| *start == block) {
            self.fetch(block)?;
        }
        let (_, bytes) = self
            .blocks
            .iter()
            .find(|(start, _)| *start == block)
            .expect("fetched block");
        let index = (self.position - block) as usize;
        if index >= bytes.len() {
            return Err(io::Error::other("incomplete metadata range"));
        }
        let count = output.len().min(bytes.len() - index);
        output[..count].copy_from_slice(&bytes[index..index + count]);
        self.position += count as u64;
        Ok(count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{BufRead, BufReader, Write},
        net::TcpListener,
        sync::atomic::{AtomicBool, AtomicUsize, Ordering},
        thread,
    };

    struct Fixture {
        url: String,
        bytes: Arc<AtomicUsize>,
        stop: Arc<AtomicBool>,
        thread: Option<thread::JoinHandle<()>>,
    }
    impl Fixture {
        fn new(data: Vec<u8>, ranges: bool) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            listener.set_nonblocking(true).unwrap();
            let stop = Arc::new(AtomicBool::new(false));
            let bytes = Arc::new(AtomicUsize::new(0));
            let done = stop.clone();
            let transferred = bytes.clone();
            let handle = thread::spawn(move || {
                while !done.load(Ordering::Relaxed) {
                    let Ok((mut socket, _)) = listener.accept() else {
                        thread::sleep(Duration::from_millis(2));
                        continue;
                    };
                    socket
                        .set_read_timeout(Some(Duration::from_secs(2)))
                        .unwrap();
                    let mut reader = BufReader::new(socket.try_clone().unwrap());
                    let mut line = String::new();
                    let mut range = (0, data.len() - 1);
                    loop {
                        line.clear();
                        if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                            break;
                        }
                        if let Some(value) = line.to_lowercase().strip_prefix("range: bytes=") {
                            let (start, end) = value.trim().split_once('-').unwrap();
                            range = (
                                start.parse().unwrap(),
                                end.parse::<usize>().unwrap().min(data.len() - 1),
                            );
                        }
                    }
                    if !ranges {
                        range = (0, data.len() - 1);
                    }
                    let body = &data[range.0..=range.1];
                    let header = if ranges {
                        format!(
                            "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {}-{}/{}\r\n",
                            range.0,
                            range.1,
                            data.len()
                        )
                    } else {
                        "HTTP/1.1 200 OK\r\n".into()
                    };
                    let _ = write!(
                        socket,
                        "{header}Content-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    if socket.write_all(body).is_ok() {
                        transferred.fetch_add(body.len(), Ordering::Relaxed);
                    }
                }
            });
            Self {
                url: format!("http://{address}/{}", "a".repeat(48)),
                bytes,
                stop,
                thread: Some(handle),
            }
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
            self.thread.take().unwrap().join().unwrap();
        }
    }
    fn atom(kind: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        [
            &((payload.len() + 8) as u32).to_be_bytes()[..],
            kind,
            payload,
        ]
        .concat()
    }
    #[test]
    fn reads_flac_tags_lyrics_cover_without_audio_download() {
        let input = [
            b"fLaC".as_slice(),
            &[0x80, 0, 0, 34],
            &[0; 34],
            &[0xff, 0xf8, 0, 0],
        ]
        .concat();
        let fields = BTreeMap::from([
            ("title".into(), "Title".into()),
            ("artist".into(), "Artist".into()),
            ("lyrics".into(), "[00:01.00]Hello\n[00:02.00]World".into()),
        ]);
        let cover = tags::CoverArt {
            data: b"\xff\xd8\xff\xd9".to_vec(),
            mime: "image/jpeg".into(),
        };
        let mut data = Vec::new();
        tags::rewrite_audio_tags(
            &mut io::Cursor::new(input),
            &mut data,
            "flac",
            &fields,
            Some(&cover.data),
            &|| Ok(()),
        )
        .unwrap();
        data.resize(32 * 1024 * 1024, 0);
        let fixture = Fixture::new(data, true);
        let tags = read(&fixture.url, "song.flac", &|| Ok(())).unwrap();
        assert_eq!(tags["title"], "Title");
        assert_eq!(tags["artist"], "Artist");
        assert_eq!(tags["lyrics"], fields["lyrics"]);
        assert_eq!(
            tags["cover_base64"],
            base64::engine::general_purpose::STANDARD.encode(cover.data)
        );
        assert!(fixture.bytes.load(Ordering::Relaxed) < 1024 * 1024);
    }
    #[test]
    fn seeks_past_audio_to_mp4_tail_tags() {
        let mut data = atom(b"ftyp", b"isom\0\0\0\0");
        data.extend(atom(b"mdat", &vec![0; 8 * 1024 * 1024]));
        let mut ilst = Vec::new();
        for (key, value) in [
            (b"\xa9nam", "Tail title"),
            (b"\xa9lyr", "[00:01.00]Tail lyrics"),
        ] {
            ilst.extend(atom(
                key,
                &atom(
                    b"data",
                    &[&[0, 0, 0, 1, 0, 0, 0, 0], value.as_bytes()].concat(),
                ),
            ));
        }
        data.extend(atom(
            b"moov",
            &atom(
                b"udta",
                &atom(
                    b"meta",
                    &[&[0; 4], atom(b"ilst", &ilst).as_slice()].concat(),
                ),
            ),
        ));
        let fixture = Fixture::new(data, true);
        let tags = read(&fixture.url, "song.m4a", &|| Ok(())).unwrap();
        assert_eq!(tags["title"], "Tail title");
        assert_eq!(tags["lyrics"], "[00:01.00]Tail lyrics");
        assert!(fixture.bytes.load(Ordering::Relaxed) < 1024 * 1024);
    }
    #[test]
    fn rejects_non_proxy_urls_and_large_servers_without_ranges() {
        for url in [
            "https://example.com/song",
            "http://192.168.1.1/song",
            "http://127.0.0.1:80/bad",
        ] {
            assert!(RangeReader::new(url, &|| Ok(())).is_err());
        }
        let fixture = Fixture::new(vec![0; 1024 * 1024], false);
        assert!(read(&fixture.url, "song.flac", &|| Ok(())).is_err());
    }
}

impl Seek for RangeReader<'_> {
    fn seek(&mut self, position: SeekFrom) -> io::Result<u64> {
        let next = match position {
            SeekFrom::Start(n) => i128::from(n),
            SeekFrom::Current(n) => i128::from(self.position) + i128::from(n),
            SeekFrom::End(n) => i128::from(self.size) + i128::from(n),
        };
        self.position =
            u64::try_from(next).map_err(|_| io::Error::other("invalid metadata seek"))?;
        Ok(self.position)
    }
}
