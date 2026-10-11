#!/usr/bin/env python3
"""yt-dlp GUI: a small window for downloading video or audio with yt-dlp (Mac and Windows, standard library only).

ffmpeg is optional. Without it, video comes as one ready-made file with the sound already in it (the best single-file
quality the site offers; on YouTube that is up to 360p) and audio comes as m4a/webm without conversion. With ffmpeg found, video is joined from the best picture and sound. It only runs yt-dlp on your links.
"""
import glob
import importlib.util
import json
import os
import queue
import re
import shutil
import struct
import subprocess
import sys
import threading
from pathlib import Path

SETTINGS = Path.home() / '.yt_dlp_gui.json'
DEFAULT_FOLDER = str(Path.home() / 'Downloads' / 'yt-dlp')
HEIGHTS = ['best', '1080', '720', '480', '360']
IS_WIN = os.name == 'nt'
IS_MAC = sys.platform == 'darwin'
URL_RE = re.compile(r'^https?://[^\s]+$', re.I)
ANSI = re.compile(r'\x1b\[[0-9;]*m')
MAX_LINKS = 20


# ---------------------------------------------------------------- core (no window needed)
def valid_url(u):
    return bool(URL_RE.match(u))


def _exe(p):
    return bool(p) and os.path.isfile(p) and os.access(p, os.X_OK)


def find_ytdlp():
    """Returns the command (a list) that runs yt-dlp, or None."""
    w = shutil.which('yt-dlp')
    if w:
        return [w]
    here = Path(__file__).resolve().parent
    home = Path.home()
    cands = [here / 'yt-dlp.exe', here / 'yt-dlp', here / 'yt-dlp_macos',
             home / 'Applications' / 'yt-dlp', home / 'Downloads' / 'yt-dlp_macos',
             home / 'Downloads' / 'yt-dlp.exe', home / 'Downloads' / 'yt-dlp',
             Path('/opt/homebrew/bin/yt-dlp'), Path('/usr/local/bin/yt-dlp')]
    for c in cands:
        if _exe(str(c)):
            return [str(c)]
    if importlib.util.find_spec('yt_dlp'):
        return [sys.executable, '-m', 'yt_dlp']
    return None


def find_js():
    """YouTube needs a JavaScript runtime for its player code. Returns (name, path) or None."""
    for name in ('node', 'deno'):
        w = shutil.which(name)
        if w:
            return name, w
    home = Path.home()
    cands = [('node', p) for p in sorted(glob.glob(str(home / '.nvm' / 'versions' / 'node' / '*' / 'bin' / 'node')), reverse=True)]
    cands += [('node', '/opt/homebrew/bin/node'), ('node', '/usr/local/bin/node'),
              ('node', r'C:\Program Files\nodejs\node.exe'), ('deno', str(home / '.deno' / 'bin' / 'deno'))]
    for n, p in cands:
        if _exe(p):
            return n, p
    return None


def find_ffmpeg():
    w = shutil.which('ffmpeg')
    if w:
        return w
    here = Path(__file__).resolve().parent
    for c in (here / 'ffmpeg.exe', here / 'ffmpeg', Path('/opt/homebrew/bin/ffmpeg'), Path('/usr/local/bin/ffmpeg')):
        if _exe(str(c)):
            return str(c)
    return None


def format_for(mode, height, ffmpeg=None, audio_format='m4a'):
    if mode == 'audio':
        return 'bestaudio/best' if audio_format == 'best' else 'bestaudio[ext=m4a]/bestaudio/best'
    if ffmpeg:   # picture and sound are joined by ffmpeg
        if height == 'best':
            return 'bv*+ba/b'
        return 'bv*[height<=%s]+ba/b[height<=%s]/b' % (height, height)
    if height == 'best':
        return 'b[ext=mp4]/b'
    return 'b[height<=%s][ext=mp4]/b[height<=%s]/b' % (height, height)


NEEDS_FFMPEG = ('That site only offers the picture and the sound as separate streams, '
                'and joining them needs ffmpeg. Audio only still works without it.')


def build_cmd(base, url, mode, height, folder, playlist, js, ffmpeg=None, audio_format='m4a'):
    cmd = list(base) + [
        '--newline', '--no-quiet', '--no-colors', '--windows-filenames',
        '-P', folder, '-o', '%(title).100s.%(ext)s',
        '--progress-template', 'download:PROG|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s',
        '--print', 'after_move:FILE|%(filepath)s',
        '--yes-playlist' if playlist else '--no-playlist',
        '-f', format_for(mode, height, ffmpeg, audio_format)]
    if ffmpeg and mode == 'video':
        cmd += ['--ffmpeg-location', ffmpeg, '--merge-output-format', 'mp4']
    elif mode == 'video':
        # YouTube's default clients no longer offer the older single-file formats (like 18, up to 360p); mweb still does.
        cmd += ['--extractor-args', 'youtube:player_client=default,mweb']
    if js:
        cmd += ['--js-runtimes', '%s:%s' % js]
    return cmd + ['--', url]


def parse_line(line):
    line = ANSI.sub('', line).strip()
    if line.startswith('PROG|'):
        parts = (line.split('|') + ['', '', ''])[:4]
        try:
            pct = float(parts[1].strip().rstrip('%'))
        except ValueError:
            return None
        return ('prog', pct, parts[2].strip(), parts[3].strip())
    if line.startswith('FILE|'):
        return ('file', line[5:])
    if line.startswith('ERROR'):
        return ('err', re.sub(r'\s+', ' ', line)[:300])
    return None


def open_path(path, reveal=False):
    try:
        if IS_WIN:
            if reveal:
                subprocess.Popen(['explorer', '/select,', os.path.normpath(path)])
            else:
                os.startfile(path)  # noqa
        elif IS_MAC:
            subprocess.Popen(['open', '-R', path] if reveal else ['open', path])
        else:
            subprocess.Popen(['xdg-open', os.path.dirname(path) if reveal else path])
    except Exception:
        pass


# ---------------------------------------------------------------- Spotify (song / album / playlist) -> search YouTube
MAX_TRACKS = 200
DURATION_SLACK = 10   # seconds either way when matching a YouTube result to the Spotify song
SPOTIFY_LINKS = [re.compile(r'^https?://open\.spotify\.com/(?:intl-[a-z-]+/)?(track|album|playlist)/([A-Za-z0-9]{22})(?:[/?#].*)?$', re.I),
                 re.compile(r'^spotify:(track|album|playlist):([A-Za-z0-9]{22})$', re.I)]
SPOTIFY_ANY = re.compile(r'^(https?://([a-z0-9-]+\.)*(spotify\.com|spotify\.link)/|spotify:)', re.I)
NEXT_DATA = re.compile(r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>', re.S)


def parse_spotify_link(s):
    for rx in SPOTIFY_LINKS:
        m = rx.match(s)
        if m:
            return m.group(1).lower(), m.group(2)
    return None


def is_spotify_address(s):
    return bool(SPOTIFY_ANY.match(s))


def new_track(title, artist, duration_ms, album='', year='', art_url='', number=0, total=0, spotify_id=''):
    return {'title': title, 'artist': artist, 'duration_ms': duration_ms, 'album': album, 'year': year,
            'art_url': art_url, 'number': number, 'total': total, 'spotify_id': spotify_id}


def best_art_url(entity):
    """The biggest cover image Spotify lists, upgraded to the 640 px version of the same picture when it is a 300 px one."""
    imgs = (entity.get('visualIdentity') or {}).get('image') or []
    imgs = [i for i in imgs if isinstance(i, dict) and i.get('url')]
    if not imgs:
        return ''
    best = max(imgs, key=lambda i: i.get('maxWidth') or 0)
    return best['url'].replace('ab67616d00001e02', 'ab67616d0000b273')


def release_year(entity):
    iso = (entity.get('releaseDate') or {}).get('isoString') or ''
    return iso[:4] if len(iso) >= 4 else ''


def spotify_entity(html):
    m = NEXT_DATA.search(html)
    if not m:
        return None
    try:
        return json.loads(m.group(1))['props']['pageProps']['state']['data']['entity']
    except (ValueError, KeyError, TypeError):
        return None


def parse_spotify_entity(e):
    name = e.get('name') or e.get('title') or 'Spotify'
    if e.get('type') == 'track':
        artists = ', '.join(a.get('name', '') for a in (e.get('artists') or []) if isinstance(a, dict) and a.get('name'))
        t = new_track(name, artists, e.get('duration') or 0, year=release_year(e), art_url=best_art_url(e), spotify_id=e.get('id') or '')
        return {'name': name, 'collection': False, 'tracks': [t]}
    items = e.get('trackList') or []
    is_album = e.get('type') == 'album'
    art = best_art_url(e) if is_album else ''   # a playlist's picture is not a song's cover; those are looked up per song
    tracks = []
    for t in items:
        title = t.get('title')
        if not title:
            continue
        tracks.append(new_track(title, t.get('subtitle') or '', t.get('duration') or 0, album=name if is_album else '',
                                art_url=art, spotify_id=(t.get('uri') or '').split(':')[-1]))
    if is_album:
        for i, t in enumerate(tracks):
            t['number'], t['total'] = i + 1, len(tracks)
    return {'name': name, 'collection': True, 'tracks': tracks} if tracks else None


def safe_file_name(s):
    t = re.sub(r'[\\/:*?"<>|\x00-\x1f]+', ' ', s)
    t = re.sub(r' +', ' ', t).strip('. ')
    return (t or 'Spotify')[:120]


def track_label(t):
    return '%s - %s' % (t['artist'], t['title']) if t['artist'] else t['title']


# Where to look on YouTube for a Spotify song, in this order: YouTube Music, a lyric video, an official video,
# any music video, and last the plain top result.
SOURCES = [('ytmusic', 'YT Music'), ('lyric', 'lyric video'), ('official', 'official video'), ('musicvideo', 'music video'), ('top', 'top result')]
UNWANTED_WORDS = ['cover', 'karaoke', 'live', 'remix', 'instrumental', 'reaction', 'slowed', 'sped up', 'nightcore', '8d', 'mashup']


def percent_encode_query(s):
    import urllib.parse
    return urllib.parse.quote(s, safe='-._~')


def track_query(t):
    return track_label(t).replace(' - ', ' ')


def ytmusic_search_url(t):
    return 'https://music.youtube.com/search?q=' + percent_encode_query(track_query(t))


def watch_links(listing, limit=5):
    """Watch links from a YouTube Music search listing (artist and album pages in the listing are ignored)."""
    out = []
    for line in listing.splitlines():
        m = re.search(r'/watch\?v=([A-Za-z0-9_-]{11})', line)
        if not m:
            continue
        url = 'https://www.youtube.com/watch?v=' + m.group(1)
        if url not in out:
            out.append(url)
        if len(out) == limit:
            break
    return out


def exclusion_filter(t):
    """Skips covers, live versions, remixes and so on, unless the song's own name says so."""
    label = track_label(t).lower()
    words = [w for w in UNWANTED_WORDS if w not in label]
    return ('title!~=(?i)\\b(' + '|'.join(words) + ')\\b') if words else None


def duration_filter(t, slack):
    if t['duration_ms'] <= 0:
        return None
    d = int(round(t['duration_ms'] / 1000.0))
    return 'duration>=%d & duration<=%d' % (d - slack, d + slack)


def ytmusic_listing_cmd(base, track, js):
    cmd = list(base) + ['--flat-playlist', '--playlist-end', '8', '--print', '%(webpage_url)s']
    if js:
        cmd += ['--js-runtimes', '%s:%s' % js]
    return cmd + ['--', ytmusic_search_url(track)]


def build_track_cmd(base, track, source, candidates, folder, js, ffmpeg=None):
    """One song from one place (audio only, m4a so the tags can be written). For 'ytmusic', `candidates` are the song
    links found by listing a YouTube Music search."""
    out = safe_file_name(track_label(track)).replace('%', '%%') + '.%(ext)s'
    cmd = build_cmd(base, 'x', 'audio', '720', folder, False, js, ffmpeg, 'm4a')[:-2]   # drop the trailing "-- x"
    cmd[cmd.index('-o') + 1] = out
    cmd += ['--max-downloads', '1']
    q = track_query(track)
    if source == 'ytmusic':
        conds, target = [duration_filter(track, DURATION_SLACK)], list(candidates)
    elif source == 'lyric':
        conds, target = [duration_filter(track, DURATION_SLACK), 'title~=(?i)lyric', exclusion_filter(track)], ['ytsearch10:%s lyrics' % q]
    elif source == 'official':
        conds, target = [duration_filter(track, 20), 'title~=(?i)official', exclusion_filter(track)], ['ytsearch10:%s official video' % q]
    elif source == 'musicvideo':
        conds, target = [duration_filter(track, 20), exclusion_filter(track)], ['ytsearch10:%s music video' % q]
    else:
        conds, target = [], ['ytsearch1:' + q]
    flt = ' & '.join(c for c in conds if c)
    if flt:
        cmd += ['--match-filter', flt]
    return cmd + ['--'] + target


def http_get(url, timeout=20):
    import urllib.request
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read() if r.status == 200 else None
    except Exception:
        return None


def fetch_spotify(kind, sid):
    body = http_get('https://open.spotify.com/embed/%s/%s' % (kind, sid), 30)
    if body is None:
        return None, 'Spotify did not answer'
    ent = spotify_entity(body.decode('utf-8', 'replace'))
    lst = parse_spotify_entity(ent) if ent else None
    if not lst:
        return None, 'Spotify did not list the songs (the playlist may be private or not available in your region)'
    return lst, ''


def enrich_track(t):
    """Fills in the cover art and year from the song's own Spotify page when the list (a playlist) did not carry them."""
    if t['art_url'] or not t['spotify_id']:
        return t
    lst, _ = fetch_spotify('track', t['spotify_id'])
    if not lst:
        return t
    first = lst['tracks'][0]
    r = dict(t)
    r['art_url'] = first['art_url']
    r['year'] = r['year'] or first['year']
    return r


def plan_jobs(lines, base_folder, log, choose=None):
    """Plain links stay as they are; Spotify links and search results ("itunes:album:123 # ...") become one job per song."""
    jobs, plain = [], 0

    def add_list(lst, why, line, source):
        if not lst:
            log('%s\n  %s' % (line, why))
            return
        folder = os.path.join(base_folder, safe_file_name(lst['name'])) if lst['collection'] else base_folder
        tracks = lst['tracks']
        if lst['collection'] and len(tracks) > 1 and choose:   # let the user pick which songs
            picked = choose(lst)
            if not picked:
                log('Skipped "%s" (no songs chosen).' % lst['name'])
                return
            tracks = [tracks[i] for i in sorted(set(picked)) if 0 <= i < len(tracks)]
        if len(tracks) > MAX_TRACKS:
            log('Only the first %d songs of "%s" are used.' % (MAX_TRACKS, lst['name']))
            tracks = tracks[:MAX_TRACKS]
        log('%s: "%s" - %s song%s. Looking on YouTube Music, then lyric videos, then music videos%s' % (
            source, lst['name'], str(len(tracks)) if len(tracks) == len(lst['tracks']) else '%d of %d' % (len(tracks), len(lst['tracks'])),
            '' if len(tracks) == 1 else 's', ', saving into a folder named after it.' if lst['collection'] else '.'))
        jobs.extend({'label': track_label(t), 'kind': 'track', 'track': t, 'folder': folder} for t in tracks)

    for line in lines:
        cref = parse_catalog_line(line)
        sref = parse_spotify_link(line)
        if cref:
            lst, why = fetch_catalog(cref)
            add_list(lst, why, line, 'Deezer' if cref[0] == 'deezer' else 'Apple')
        elif sref:
            lst, why = fetch_spotify(*sref)
            add_list(lst, why, line, 'Spotify')
        elif is_spotify_address(line):
            log('%s\n  Only Spotify song, album and playlist links work. Artist, podcast and short links are not supported; '
                'open the link in your browser and copy the song, album or playlist address.' % line)
        elif valid_url(line):
            plain += 1
            if plain > MAX_LINKS:
                if plain == MAX_LINKS + 1:
                    log('Only the first %d plain links are used.' % MAX_LINKS)
                continue
            jobs.append({'label': line, 'kind': 'link', 'url': line, 'folder': base_folder})
        else:
            log('Skipped (not an http/https link or search result): ' + line[:60])
    return jobs


# ---------------------------------------------------------------- music search without any account or key:
# Apple's free catalog (songs, albums, artists) and Deezer's (playlists). Results become lines like
# "itunes:album:123 # The Beatles - Abbey Road" in the link box; Download turns each line into its songs.
CATALOG_LINE = re.compile(r'^(itunes|deezer):(song|album|playlist):(\d+)(?:\s+#.*)?$', re.I)


def parse_catalog_line(s):
    m = CATALOG_LINE.match(s)
    return (m.group(1).lower(), m.group(2).lower(), m.group(3)) if m else None


def new_hit(hid, title, subtitle='', detail=''):
    return {'id': hid, 'title': title, 'subtitle': subtitle, 'detail': detail}


def hit_line(h):
    """The line added to the link box (the part after # is only a label for you)."""
    return '%s # %s' % (h['id'], ('%s - %s' % (h['subtitle'], h['title'])) if h['subtitle'] else h['title'])


class Throttle:
    """Apple's free API allows roughly 20 requests a minute, so space the calls out."""

    def __init__(self):
        self.lock = threading.Lock()
        self.last = 0.0

    def wait(self, interval):
        import time
        with self.lock:
            gap = time.time() - self.last
            if gap < interval:
                time.sleep(interval - gap)
            self.last = time.time()


ITUNES_THROTTLE, DEEZER_THROTTLE = Throttle(), Throttle()


def fetch_json(url, throttle, interval):
    for attempt in range(2):
        throttle.wait(interval if attempt == 0 else 2.5)
        body = http_get(url)
        if body:
            try:
                return json.loads(body.decode('utf-8', 'replace'))
            except ValueError:
                pass
    return None


def itunes_json(url):
    return fetch_json(url, ITUNES_THROTTLE, 0.6)


def deezer_json(url):
    return fetch_json(url, DEEZER_THROTTLE, 0.25)


def big_art(url):
    return (url or '').replace('100x100bb', '1000x1000bb')


def year_of(iso):
    return iso[:4] if isinstance(iso, str) and len(iso) >= 4 else ''


def itunes_track(r):
    name = r.get('trackName')
    if not name:
        return None
    return new_track(name, r.get('artistName') or '', r.get('trackTimeMillis') or 0, album=r.get('collectionName') or '',
                     year=year_of(r.get('releaseDate')), art_url=big_art(r.get('artworkUrl100')),
                     number=r.get('trackNumber') or 0, total=r.get('trackCount') or 0)


def itunes_song_hits(j):
    out = []
    for r in j.get('results') or []:
        t = itunes_track(r) if r.get('kind') == 'song' and r.get('trackId') else None
        if not t:
            continue
        detail = ' · '.join(x for x in (t['album'], t['year']) if x)
        if t['duration_ms'] > 0:
            detail += (' · ' if detail else '') + '%d:%02d' % (t['duration_ms'] // 60000, (t['duration_ms'] // 1000) % 60)
        out.append(new_hit('itunes:song:%d' % r['trackId'], t['title'], t['artist'], detail))
    return out


def itunes_album_hits(j):
    out = []
    for r in j.get('results') or []:
        n = r.get('trackCount') or 0
        if not r.get('collectionId') or not r.get('collectionName') or n <= 0:
            continue
        detail = ' · '.join(x for x in (year_of(r.get('releaseDate')), '%d song%s' % (n, '' if n == 1 else 's')) if x)
        out.append(new_hit('itunes:album:%d' % r['collectionId'], r['collectionName'], r.get('artistName') or '', detail))
    return out


def itunes_artist_hits(j):
    return [new_hit('itunes:artist:%d' % r['artistId'], r['artistName'], '', r.get('primaryGenreName') or '')
            for r in j.get('results') or [] if r.get('artistId') and r.get('artistName')]


def deezer_playlist_hits(j):
    out = []
    for r in j.get('data') or []:
        if not r.get('id') or not r.get('title'):
            continue
        n = r.get('nb_tracks') or 0
        out.append(new_hit('deezer:playlist:%d' % r['id'], r['title'], (r.get('user') or {}).get('name') or '', '%d song%s' % (n, '' if n == 1 else 's')))
    return out


def folded_album_name(s):
    """"Abbey Road (Deluxe Edition)", "Abbey Road - Remastered" and "Abbey Road" are one album for our purposes."""
    t = s.lower()
    t = re.sub(r'\s*[\(\[].*?[\)\]]', '', t)
    t = re.sub(r'\s+-\s+(single|ep)$', '', t)
    t = re.sub(r'\b(deluxe|remastered|remaster|expanded|edition|version|bonus|anniversary|explicit)\b', '', t)
    return re.sub(r'[\W_]+', ' ', t).strip()


def folded_album_hits(j):
    """An artist's albums: duplicate editions folded into one (the one with the most songs is kept), newest first."""
    rows = [r for r in (j.get('results') or []) if r.get('wrapperType') == 'collection' and r.get('collectionId') and (r.get('trackCount') or 0) > 0]
    best, order = {}, []
    for r in rows:
        key = folded_album_name(r.get('collectionName') or '')
        if key in best:
            if (r.get('trackCount') or 0) > (best[key].get('trackCount') or 0):
                best[key] = r
        else:
            best[key] = r
            order.append(key)
    kept = sorted((best[k] for k in order), key=lambda r: r.get('releaseDate') or '', reverse=True)
    return itunes_album_hits({'results': kept})


def deezer_track(r):
    if not r.get('title'):
        return None
    album = r.get('album') or {}
    return new_track(r['title'], (r.get('artist') or {}).get('name') or '', (r.get('duration') or 0) * 1000,
                     album=album.get('title') or '', art_url=album.get('cover_xl') or album.get('cover_big') or '')


CATALOG_DOWN = {'itunes': "Apple's catalog did not answer. Try again in a moment.", 'deezer': 'Deezer did not answer. Try again in a moment.'}


def search_catalog(kind, query):
    """Returns (hits, error)."""
    q = percent_encode_query(query)
    if kind == 'playlist':
        j = deezer_json('https://api.deezer.com/search/playlist?q=%s&limit=30' % q)
        return (deezer_playlist_hits(j), '') if j is not None else ([], CATALOG_DOWN['deezer'])
    entity, limit, fn = {'song': ('song', 30, itunes_song_hits), 'album': ('album', 30, itunes_album_hits)}.get(kind, ('musicArtist', 15, itunes_artist_hits))
    j = itunes_json('https://itunes.apple.com/search?term=%s&entity=%s&limit=%d' % (q, entity, limit))
    return (fn(j), '') if j is not None else ([], CATALOG_DOWN['itunes'])


def artist_albums(artist_id):
    j = itunes_json('https://itunes.apple.com/lookup?id=%s&entity=album&limit=200' % artist_id)
    if j is None:
        return [], CATALOG_DOWN['itunes']
    hits = folded_album_hits(j)
    return hits, ('' if hits else 'No albums found for this artist.')


def fetch_catalog(ref):
    """Turns ('itunes', 'album', '123') and friends into a list of songs with their tags. Returns (list or None, error)."""
    source, kind, cid = ref
    if (source, kind) == ('itunes', 'song'):
        j = itunes_json('https://itunes.apple.com/lookup?id=%s' % cid)
        t = itunes_track((j.get('results') or [{}])[0]) if j else None
        return ({'name': t['title'], 'collection': False, 'tracks': [t]}, '') if t else (None, "Apple's catalog does not have that song")
    if (source, kind) == ('itunes', 'album'):
        j = itunes_json('https://itunes.apple.com/lookup?id=%s&entity=song&limit=200' % cid)
        if j is None:
            return None, "Apple's catalog did not answer"
        rows = j.get('results') or []
        name = next((r.get('collectionName') for r in rows if r.get('wrapperType') == 'collection'), 'Album')
        songs = sorted((r for r in rows if r.get('kind') == 'song'), key=lambda r: (r.get('discNumber') or 1, r.get('trackNumber') or 0))
        tracks = [t for t in (itunes_track(r) for r in songs) if t]
        return ({'name': name, 'collection': True, 'tracks': tracks}, '') if tracks else (None, "That album has no songs in Apple's catalog")
    if (source, kind) == ('deezer', 'playlist'):
        meta = deezer_json('https://api.deezer.com/playlist/%s' % cid)
        if not meta or not meta.get('title'):
            return None, 'Deezer did not answer'
        tracks, nxt = [], 'https://api.deezer.com/playlist/%s/tracks?limit=100' % cid
        while nxt and len(tracks) < MAX_TRACKS:
            page = deezer_json(nxt)
            if not page:
                break
            tracks += [t for t in (deezer_track(r) for r in page.get('data') or []) if t]
            nxt = page.get('next')
        return ({'name': meta['title'], 'collection': True, 'tracks': tracks}, '') if tracks else (None, 'That playlist has no songs (it may be private)')
    return None, 'Unsupported item'


# ---------------------------------------------------------------- writing tags + cover art into an .m4a (no ffmpeg, standard library only)
def _box(kind, payload):
    return struct.pack('>I4s', 8 + len(payload), kind) + payload


def _data_atom(flags, payload):
    return _box(b'data', struct.pack('>II', flags, 0) + payload)


def _boxes(buf, start, end):
    pos = start
    while pos + 8 <= end:
        size, kind = struct.unpack_from('>I4s', buf, pos)
        hdr = 8
        if size == 1:
            size, hdr = struct.unpack_from('>Q', buf, pos + 8)[0], 16
        elif size == 0:
            size = end - pos
        if size < hdr or pos + size > end:
            raise ValueError('damaged file (bad box)')
        yield kind, pos, pos + size, hdr
        pos += size


def _patch_offsets(buf, start, end, delta):
    for kind, s, e, h in _boxes(buf, start, end):
        if kind in (b'trak', b'mdia', b'minf', b'stbl'):
            _patch_offsets(buf, s + h, e, delta)
        elif kind in (b'stco', b'co64'):
            wide = kind == b'co64'
            fmt, step = ('>Q', 8) if wide else ('>I', 4)
            n = struct.unpack_from('>I', buf, s + h + 4)[0]
            for i in range(n):
                off = s + h + 8 + step * i
                struct.pack_into(fmt, buf, off, struct.unpack_from(fmt, buf, off)[0] + delta)


def build_ilst(track, art):
    def text(code, value):
        return _box(code, _data_atom(1, value.encode('utf-8')))
    items = [text(b'\xa9nam', track['title']), text(b'\xa9ART', track['artist'])]
    if track['artist']:
        items.append(text(b'aART', track['artist'].split(', ')[0]))
    if track['album']:
        items.append(text(b'\xa9alb', track['album']))
    if track['year']:
        items.append(text(b'\xa9day', track['year']))
    if track['number'] > 0:
        items.append(_box(b'trkn', _data_atom(0, struct.pack('>HHHH', 0, min(track['number'], 65535), min(track['total'], 65535), 0))))
    if art:
        items.append(_box(b'covr', _data_atom(14 if art[:2] == b'\x89P' else 13, art)))
    return _box(b'ilst', b''.join(items))


def tag_m4a_bytes(data, track, art=None):
    """Returns the file with title/artist/album/year/track number/cover art written in. Raises ValueError if the file
    is not a normal MP4 audio file."""
    top = list(_boxes(data, 0, len(data)))
    moov = [(s, e, h) for k, s, e, h in top if k == b'moov']
    if not moov:
        raise ValueError('no moov box')
    ms, me, mh = moov[0]
    mdat_after = any(k == b'mdat' and s > ms for k, s, e, h in top)
    keep = b''.join(bytes(data[s:e]) for k, s, e, h in _boxes(data, ms + mh, me) if k != b'udta')
    hdlr = _box(b'hdlr', b'\x00' * 8 + b'mdir' + b'appl' + b'\x00' * 8 + b'\x00')
    payload = bytearray(keep + _box(b'udta', _box(b'meta', b'\x00\x00\x00\x00' + hdlr + build_ilst(track, art))))
    delta = 8 + len(payload) - (me - ms)
    if mdat_after and delta:
        _patch_offsets(payload, 0, len(payload), delta)
    return bytes(data[:ms]) + _box(b'moov', bytes(payload)) + bytes(data[me:])


def tag_m4a(path, track):
    """Tags the file in place. Returns None on success, or a short note (tags written but no cover, or why it failed)."""
    track = enrich_track(track)
    art, note = None, ''
    if track['art_url']:
        art = http_get(track['art_url'])
        if not art or len(art) < 1000:
            art, note = None, ' (cover art could not be downloaded)'
    else:
        note = ' (no cover art found)'
    try:
        with open(path, 'rb') as f:
            data = f.read()
        out = tag_m4a_bytes(data, track, art)
        tmp = path + '.tagging'
        with open(tmp, 'wb') as f:
            f.write(out)
        os.replace(tmp, path)
    except (ValueError, OSError) as e:
        return 'could not write tags: %s' % e
    return ('tags written' + note) if note else None


class Downloader:
    """Plans the jobs (Spotify links become one job per song), then runs them one after another on a background thread
    and reports through a queue."""

    def __init__(self, events):
        self.events = events
        self.proc = None
        self.cancelled = False
        self.sources = [k for k, _ in SOURCES]   # tests can limit which places are tried
        self.debug = bool(os.environ.get('YTGUI_DEBUG'))

    def start(self, base, lines, mode, height, folder, playlist, js, ffmpeg=None, audio_format='m4a', choose_songs=False):
        self.cancelled = False
        self.choose_songs = choose_songs
        threading.Thread(target=self._run, args=(base, lines, mode, height, folder, playlist, js, ffmpeg, audio_format), daemon=True).start()

    def stop(self):
        self.cancelled = True
        p = self.proc
        if p and p.poll() is None:
            try:
                p.terminate()
            except Exception:
                pass

    def _log(self, text):
        self.events.put(('log', text))

    def _ask(self, lst):
        """Called from the worker thread: the window shows the song list and the answer comes back through a queue."""
        reply = queue.Queue()
        self.events.put(('choose', lst['name'], lst['tracks'], reply))
        return reply.get()

    def _run_retry(self, i, cmd):
        """YouTube sometimes answers a download with "403 Forbidden" for no lasting reason, so try up to 3 times."""
        code, err, path = self._run_one(i, cmd)
        attempt = 1
        while not path and code != 0 and not self.cancelled and 'HTTP Error 403' in err and attempt < 3:
            attempt += 1
            self.events.put(('row', i, 'Retrying (%d/3)...' % attempt))
            code, err, path = self._run_one(i, cmd)
        return code, err, path

    def _capture(self, cmd):
        """Runs yt-dlp and returns what it printed (used to list YouTube Music search results)."""
        flags = subprocess.CREATE_NO_WINDOW if IS_WIN else 0
        try:
            self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                                         encoding='utf-8', errors='replace', creationflags=flags)
            out = self.proc.communicate()[0]
            return out or ''
        except Exception:
            return ''

    def _run_one(self, i, cmd):
        flags = subprocess.CREATE_NO_WINDOW if IS_WIN else 0
        err, last_file = '', None
        try:
            self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                         encoding='utf-8', errors='replace', creationflags=flags)
            for raw in self.proc.stdout:
                ev = parse_line(raw)
                if not ev:
                    continue
                if ev[0] == 'prog':
                    self.events.put(('prog', i, ev[1], ev[2], ev[3]))
                elif ev[0] == 'file':
                    last_file = ev[1]
                    self.events.put(('file', i, last_file))
                elif ev[0] == 'err':
                    err = ev[1]
            code = self.proc.wait()
        except Exception as e:
            return 1, 'could not run yt-dlp: %s' % e, None
        return code, err, last_file

    def _run(self, base, lines, mode, height, folder, playlist, js, ffmpeg, audio_format):
        jobs = plan_jobs(lines, folder, self._log, self._ask if self.choose_songs else None)
        self.events.put(('plan', [j['label'] for j in jobs]))
        for i, job in enumerate(jobs):
            if self.cancelled:
                self.events.put(('row', i, 'Cancelled'))
                continue
            self.events.put(('row', i, 'Starting...'))
            try:
                os.makedirs(job['folder'], exist_ok=True)
            except OSError:
                pass
            if job['kind'] == 'link':
                code, err, _ = self._run_retry(i, build_cmd(base, job['url'], mode, height, job['folder'], playlist, js, ffmpeg, audio_format))
                if self.cancelled:
                    self.events.put(('row', i, 'Cancelled'))
                elif code == 0:
                    self.events.put(('row', i, 'Done'))
                else:
                    self.events.put(('row', i, 'Failed'))
                    why = err or 'yt-dlp stopped with an error (exit code %s)' % code
                    if mode == 'video' and not ffmpeg and 'Requested format is not available' in why:
                        why = NEEDS_FFMPEG
                    self._log('%s\n  %s' % (job['url'], why))
                continue
            # a Spotify song: always audio (m4a, so the tags and cover art can be written).
            # Look in order: YouTube Music, a lyric video, an official video, any music video, the top result.
            t = job['track']
            found, last_error = None, ''
            labels = dict(SOURCES)
            for source in self.sources:
                if self.cancelled:
                    break
                self.events.put(('row', i, 'Looking: %s...' % labels[source]))
                candidates = []
                if source == 'ytmusic':
                    candidates = watch_links(self._capture(ytmusic_listing_cmd(base, t, js)))
                    if not candidates:
                        if self.debug:
                            self._log('debug: %s: no song links in the listing' % labels[source])
                        continue
                code, err, path = self._run_retry(i, build_track_cmd(base, t, source, candidates, job['folder'], js, ffmpeg))
                if path:
                    found = (path, source)
                    break
                if self.debug:
                    self._log('debug: %s: nothing (exit %s) %s' % (labels[source], code, err))
                if err:
                    last_error = err
            if self.cancelled:
                self.events.put(('row', i, 'Cancelled'))
            elif found:
                path, source = found
                status = 'Done (%s)' % labels[source]
                if path.lower().endswith('.m4a'):
                    self.events.put(('row', i, 'Adding tags...'))
                    note = tag_m4a(path, t)
                    if note:
                        status += ' - tags: see log'
                        self._log('%s\n  %s' % (job['label'], note))
                else:
                    status += ' - no tags'
                    self._log('%s\n  Saved as %s, which cannot hold tags.' % (job['label'], os.path.splitext(path)[1]))
                self.events.put(('row', i, status))
            else:
                self.events.put(('row', i, 'Failed'))
                self._log('%s\n  %s' % (job['label'], last_error or 'No match found on YouTube Music, lyric videos or music videos.'))
        self.events.put(('finished',))


def load_settings():
    try:
        d = json.loads(SETTINGS.read_text(encoding='utf-8'))
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def save_settings(d):
    try:
        SETTINGS.write_text(json.dumps(d), encoding='utf-8')
    except Exception:
        pass


# ---------------------------------------------------------------- window
def main(smoke=False, shot=None):
    import tkinter as tk
    from tkinter import filedialog, messagebox, ttk

    class App(tk.Tk):
        def __init__(self):
            super().__init__()
            self.title('yt-dlp GUI')
            self.minsize(640, 560)
            self.events = queue.Queue()
            self.dl = Downloader(self.events)
            self.base = find_ytdlp()
            self.js = find_js()
            self.ffmpeg = find_ffmpeg()
            self.files = {}
            self.busy = False
            s = load_settings()
            self.mode = tk.StringVar(value=s.get('mode', 'video') if s.get('mode') in ('audio', 'video') else 'video')
            self.height = tk.StringVar(value=s.get('height', '720') if s.get('height') in HEIGHTS else '720')
            self.audio_format = tk.StringVar(value=s.get('audio_format', 'm4a') if s.get('audio_format') in ('m4a', 'best') else 'm4a')
            self.playlist = tk.BooleanVar(value=bool(s.get('playlist', False)))
            self.ask_songs = tk.BooleanVar(value=bool(s.get('ask_songs', True)))
            self.folder = tk.StringVar(value=s.get('folder') or DEFAULT_FOLDER)
            self.build()
            self.mode_changed()
            self.after(100, self.poll)
            if not self.base:
                self.notice('yt-dlp was not found. Put the yt-dlp program in your Downloads folder (or next to this app) and restart. Get it from github.com/yt-dlp/yt-dlp/releases.')
            elif not self.js:
                self.notice('Tip: install Node.js (nodejs.org) so YouTube links work reliably. Other sites are fine without it.')

        def build(self):
            pad = {'padx': 12, 'pady': 4}
            ttk.Label(self, text='Links (one per line)').pack(anchor='w', **pad)
            ttk.Label(self, foreground='#777777', wraplength=600, justify='left',
                      text='Website links, a Spotify song, album or playlist link, or press Search... to find music by name. Songs from Spotify and the search are always saved as audio (m4a) with title, artist, cover art and more written in.').pack(anchor='w', padx=12)
            box = ttk.Frame(self)
            box.pack(fill='x', padx=12)
            self.links = tk.Text(box, height=5, wrap='none', undo=True)
            self.links.pack(side='left', fill='x', expand=True)
            side = ttk.Frame(box)
            side.pack(side='left', padx=(8, 0), anchor='n')
            ttk.Button(side, text='Paste', command=self.paste).pack(fill='x')
            ttk.Button(side, text='Search...', command=self.search_dialog).pack(fill='x', pady=(4, 0))

            row = ttk.Frame(self)
            row.pack(fill='x', **pad)
            ttk.Radiobutton(row, text='Video', variable=self.mode, value='video', command=self.mode_changed).pack(side='left')
            ttk.Radiobutton(row, text='Audio only', variable=self.mode, value='audio', command=self.mode_changed).pack(side='left', padx=(10, 16))
            ttk.Label(row, text='Max height').pack(side='left')
            self.height_box = ttk.Combobox(row, textvariable=self.height, values=HEIGHTS, width=6, state='readonly')
            self.height_box.pack(side='left', padx=(6, 16))
            ttk.Checkbutton(row, text='Whole playlist', variable=self.playlist).pack(side='left', padx=(0, 10))
            ttk.Checkbutton(row, text='Choose songs', variable=self.ask_songs).pack(side='left', padx=(0, 16))
            ttk.Label(row, text='Audio').pack(side='left')
            self.audio_box = ttk.Combobox(row, textvariable=self.audio_format, values=['m4a', 'best'], width=6, state='readonly')
            self.audio_box.pack(side='left', padx=(6, 0))
            self.audio_box.bind('<<ComboboxSelected>>', lambda e: self.mode_changed())

            self.hint = ttk.Label(self, foreground='#777777', wraplength=600, justify='left')
            self.hint.pack(anchor='w', padx=12)

            frow = ttk.Frame(self)
            frow.pack(fill='x', **pad)
            ttk.Label(frow, text='Save to').pack(side='left')
            ttk.Entry(frow, textvariable=self.folder).pack(side='left', fill='x', expand=True, padx=6)
            ttk.Button(frow, text='Choose...', command=self.choose).pack(side='left')
            ttk.Button(frow, text='Open folder', command=self.open_folder).pack(side='left', padx=(6, 0))

            brow = ttk.Frame(self)
            brow.pack(fill='x', **pad)
            self.go = ttk.Button(brow, text='Download', command=self.start)
            self.go.pack(side='left')
            self.stop_btn = ttk.Button(brow, text='Cancel', command=self.dl.stop)
            self.stop_btn.pack(side='left', padx=8)
            self.bar = ttk.Progressbar(brow, maximum=100)
            self.bar.pack(side='left', fill='x', expand=True, padx=(8, 0))
            self.speed = ttk.Label(self, text='')
            self.speed.pack(anchor='w', padx=12)

            self.tree = ttk.Treeview(self, columns=('link', 'status'), show='headings', height=6)
            self.tree.heading('link', text='Link')
            self.tree.heading('status', text='Status')
            self.tree.column('link', width=430)
            self.tree.column('status', width=160, anchor='w')
            self.tree.pack(fill='both', expand=True, padx=12, pady=(4, 4))
            self.tree.bind('<Double-1>', self.reveal)
            ttk.Label(self, text='Double-click a finished row to show the file.', foreground='#777777').pack(anchor='w', padx=12)

            self.log = tk.Text(self, height=5, wrap='word', state='disabled')
            self.log.pack(fill='x', padx=12, pady=(4, 12))

        def mode_changed(self):
            video = self.mode.get() == 'video'
            self.height_box.configure(state='readonly' if video else 'disabled')
            self.audio_box.configure(state='disabled' if video else 'readonly')
            if not video:
                msg = ('Audio "best": the highest-quality audio the site has, often .webm (opus). YouTube audio tops out around 130-160 kbps either way.'
                       if self.audio_format.get() == 'best' else
                       'Audio "m4a": plays on every device. YouTube audio tops out around 128-160 kbps, so this is close to the best there is.')
            elif self.ffmpeg:
                msg = 'ffmpeg found: video is joined from the best picture and sound, up to the height you choose.'
            else:
                msg = 'No ffmpeg: video is saved as one file with sound in it, the best single-file quality the site offers On YouTube that is up to 360p, so a higher max height only helps on other sites.'
            self.hint.configure(text=msg)

        def notice(self, text):
            self.write_log(text)

        def write_log(self, text):
            self.log.configure(state='normal')
            self.log.insert('end', text + '\n')
            self.log.see('end')
            self.log.configure(state='disabled')

        def paste(self):
            try:
                self.links.insert('end', self.clipboard_get().strip() + '\n')
            except tk.TclError:
                pass

        def choose(self):
            d = filedialog.askdirectory(initialdir=self.folder.get() or str(Path.home()))
            if d:
                self.folder.set(d)

        def open_folder(self):
            f = os.path.expanduser(self.folder.get())
            os.makedirs(f, exist_ok=True)
            open_path(f)

        def reveal(self, _e):
            sel = self.tree.selection()
            if sel and int(sel[0]) in self.files:
                open_path(self.files[int(sel[0])], reveal=True)

        def start(self):
            if self.busy:
                return
            if not self.base:
                messagebox.showerror('yt-dlp', 'yt-dlp was not found. See the note at the bottom of the window.')
                return
            lines = [l.strip() for l in self.links.get('1.0', 'end').splitlines() if l.strip()]
            if not lines:
                messagebox.showinfo('yt-dlp', 'Paste at least one link (a website link or a Spotify song, album or playlist link)')
                return
            folder = os.path.expanduser(self.folder.get().strip() or DEFAULT_FOLDER)
            try:
                os.makedirs(folder, exist_ok=True)
            except OSError as e:
                messagebox.showerror('Save to', 'Cannot use that folder: %s' % e)
                return
            save_settings({'mode': self.mode.get(), 'height': self.height.get(), 'audio_format': self.audio_format.get(), 'playlist': self.playlist.get(), 'ask_songs': self.ask_songs.get(), 'folder': folder})
            self.tree.delete(*self.tree.get_children())
            self.files = {}
            self.busy = True
            self.go.configure(state='disabled')
            self.bar['value'] = 0
            self.dl.start(self.base, lines, self.mode.get(), self.height.get(), folder, self.playlist.get(), self.js, self.ffmpeg, self.audio_format.get(), self.ask_songs.get())

        def add_links(self, lines):
            cur = self.links.get('1.0', 'end-1c')
            self.links.insert('end', ('' if not cur or cur.endswith('\n') else '\n') + '\n'.join(lines) + '\n')

        def search_dialog(self):
            """Look up songs, albums, artists or playlists and add them to the link box."""
            win = tk.Toplevel(self)
            win.title('Search music')
            win.geometry('680x560')
            win.transient(self)
            kinds = {'Songs': 'song', 'Albums': 'album', 'Artists': 'artist', 'Playlists': 'playlist'}
            st = {'hits': [], 'artist': None, 'artist_hits': [], 'busy': False}
            inbox = queue.Queue()
            top = ttk.Frame(win)
            top.pack(fill='x', padx=12, pady=(12, 4))
            kind_var, query_var = tk.StringVar(value='Songs'), tk.StringVar()
            kind_box = ttk.Combobox(top, textvariable=kind_var, values=list(kinds), width=10, state='readonly')
            kind_box.pack(side='left')
            entry = ttk.Entry(top, textvariable=query_var)
            entry.pack(side='left', fill='x', expand=True, padx=6)
            search_btn = ttk.Button(top, text='Search')
            search_btn.pack(side='left')
            head = ttk.Label(win, font=('TkDefaultFont', 11, 'bold'))
            head.pack(anchor='w', padx=12)
            msg = ttk.Label(win, foreground='#777777', wraplength=640, justify='left')
            msg.pack(anchor='w', padx=12)
            frame = ttk.Frame(win)
            frame.pack(fill='both', expand=True, padx=12, pady=6)
            tree = ttk.Treeview(frame, columns=('title', 'detail'), show='headings', selectmode='extended')
            tree.heading('title', text='Title')
            tree.heading('detail', text='Details')
            tree.column('title', width=360)
            tree.column('detail', width=240)
            sb = ttk.Scrollbar(frame, orient='vertical', command=tree.yview)
            tree.configure(yscrollcommand=sb.set)
            tree.pack(side='left', fill='both', expand=True)
            sb.pack(side='left', fill='y')
            bar = ttk.Frame(win)
            bar.pack(fill='x', padx=12, pady=(0, 12))
            back_btn = ttk.Button(bar, text='< Back to artists')
            albums_btn = ttk.Button(bar, text='Show albums')
            all_btn = ttk.Button(bar, text='Select all')
            add_btn = ttk.Button(bar, text='Add')
            close_btn = ttk.Button(bar, text='Close', command=win.destroy)
            foot = ttk.Label(bar, foreground='#777777')
            foot.pack(side='left')
            close_btn.pack(side='right')
            add_btn.pack(side='right', padx=6)
            all_btn.pack(side='right')
            albums_btn.pack(side='right', padx=6)
            back_btn.pack(side='right')

            def label_of(h):
                return ('%s  -  %s' % (h['title'], h['subtitle'])) if h['subtitle'] else h['title']

            def refresh_mode():
                kind = kinds[kind_var.get()]
                browsing_artists = kind == 'artist' and st['artist'] is None
                in_albums = st['artist'] is not None
                back_btn.configure(state='normal' if in_albums else 'disabled')
                albums_btn.configure(state='normal' if browsing_artists else 'disabled')
                all_btn.configure(state='disabled' if browsing_artists else 'normal')
                add_btn.configure(state='disabled' if browsing_artists else 'normal')
                head.configure(text=('Albums by %s' % st['artist']['title']) if in_albums else '')
                top_state = 'disabled' if in_albums else 'normal'
                for w in (kind_box, entry, search_btn):
                    w.configure(state=('readonly' if (w is kind_box and top_state == 'normal') else top_state))
                foot.configure(text='Playlists come from Deezer; the rest from Apple\'s free catalog.' if kinds[kind_var.get()] == 'playlist' else 'Songs, albums and artists come from Apple\'s free catalog.')

            def fill(hits, select_all=False):
                st['hits'] = hits
                tree.delete(*tree.get_children())
                for i, h in enumerate(hits):
                    tree.insert('', 'end', iid=str(i), values=(label_of(h), h['detail']))
                if select_all and hits:
                    tree.selection_set(tree.get_children())

            def run_in_background(fn, tag):
                if st['busy']:
                    return
                st['busy'] = True
                msg.configure(text='Searching...')
                threading.Thread(target=lambda: inbox.put((tag, fn())), daemon=True).start()

            def do_search(_e=None):
                q = query_var.get().strip()
                if not q:
                    return
                kind = kinds[kind_var.get()]
                st['artist'] = None
                run_in_background(lambda: search_catalog(kind, q), 'hits')

            def show_albums(_e=None):
                sel = tree.selection()
                if kinds[kind_var.get()] != 'artist' or st['artist'] is not None or not sel:
                    return
                hit = st['hits'][int(sel[0])]
                st['artist_hits'], st['pending_artist'] = st['hits'], hit
                run_in_background(lambda: artist_albums(hit['id'].split(':')[-1]), 'albums')

            def back():
                st['artist'] = None
                fill(st['artist_hits'])
                msg.configure(text='')
                refresh_mode()

            def add_selected():
                lines = [hit_line(st['hits'][int(i)]) for i in tree.selection()]
                if not lines:
                    return
                self.add_links(lines)
                tree.selection_remove(tree.selection())
                msg.configure(text='Added %d. They are now in the link box.' % len(lines))

            def pump():
                try:
                    while True:
                        tag, (hits, err) = inbox.get_nowait()
                        st['busy'] = False
                        if tag == 'hits':
                            fill(hits)
                            msg.configure(text=err or ('' if hits else 'Nothing found. Try fewer words or another spelling.'))
                        elif hits:
                            st['artist'] = st['pending_artist']
                            fill(hits, select_all=True)
                            msg.configure(text="Duplicate editions (Deluxe, Remastered...) are folded into one. Untick what you do not want.")
                        else:
                            msg.configure(text=err)
                        refresh_mode()
                except queue.Empty:
                    pass
                if win.winfo_exists():
                    win.after(100, pump)

            search_btn.configure(command=do_search)
            entry.bind('<Return>', do_search)
            kind_box.bind('<<ComboboxSelected>>', lambda e: (fill([]), msg.configure(text=''), refresh_mode()))
            back_btn.configure(command=back)
            albums_btn.configure(command=show_albums)
            all_btn.configure(command=lambda: tree.selection_set(tree.get_children()))
            add_btn.configure(command=add_selected)
            tree.bind('<Double-1>', show_albums)
            refresh_mode()
            pump()
            entry.focus_set()

        def choose_dialog(self, name, tracks, reply):
            """A window listing the songs of an album or playlist; the user ticks the ones to download."""
            win = tk.Toplevel(self)
            win.title(name)
            win.geometry('520x460')
            win.transient(self)
            ttk.Label(win, text=name, font=('TkDefaultFont', 12, 'bold')).pack(anchor='w', padx=12, pady=(12, 0))
            ttk.Label(win, text='Pick the songs to download (click, or Shift/Ctrl-click for several).', foreground='#777777').pack(anchor='w', padx=12)
            frame = ttk.Frame(win)
            frame.pack(fill='both', expand=True, padx=12, pady=8)
            lb = tk.Listbox(frame, selectmode='extended', activestyle='none')
            sb = ttk.Scrollbar(frame, orient='vertical', command=lb.yview)
            lb.configure(yscrollcommand=sb.set)
            for i, t in enumerate(tracks):
                secs = int(round(t['duration_ms'] / 1000.0))
                lb.insert('end', '%3d.  %s%s' % (i + 1, track_label(t), ('   (%d:%02d)' % (secs // 60, secs % 60)) if secs else ''))
            lb.selection_set(0, 'end')
            lb.pack(side='left', fill='both', expand=True)
            sb.pack(side='left', fill='y')
            count = ttk.Label(win)
            count.pack(anchor='w', padx=12)
            answered = []

            def refresh(_e=None):
                count.configure(text='%d of %d selected' % (len(lb.curselection()), len(tracks)))
                ok.configure(state='normal' if lb.curselection() else 'disabled')

            def answer(value):
                if answered:
                    return
                answered.append(1)
                reply.put(value)
                win.destroy()

            bar = ttk.Frame(win)
            bar.pack(fill='x', padx=12, pady=(4, 12))
            ttk.Button(bar, text='Select all', command=lambda: (lb.selection_set(0, 'end'), refresh())).pack(side='left')
            ttk.Button(bar, text='Select none', command=lambda: (lb.selection_clear(0, 'end'), refresh())).pack(side='left', padx=6)
            ttk.Button(bar, text='Skip this one', command=lambda: answer([])).pack(side='right')
            ok = ttk.Button(bar, text='Download selected', command=lambda: answer(list(lb.curselection())))
            ok.pack(side='right', padx=6)
            lb.bind('<<ListboxSelect>>', refresh)
            win.protocol('WM_DELETE_WINDOW', lambda: answer([]))
            refresh()
            win.grab_set()

        def poll(self):
            try:
                while True:
                    ev = self.events.get_nowait()
                    if ev[0] == 'choose':
                        self.choose_dialog(ev[1], ev[2], ev[3])
                    elif ev[0] == 'plan':
                        for i, label in enumerate(ev[1]):
                            self.tree.insert('', 'end', iid=str(i), values=(label, 'Waiting'))
                    elif ev[0] == 'row':
                        self.tree.set(str(ev[1]), 'status', ev[2])
                        if ev[2].startswith('Done') or ev[2] in ('Failed', 'Cancelled'):
                            self.bar['value'] = 100 if ev[2].startswith('Done') else 0
                            self.speed.configure(text='')
                    elif ev[0] == 'prog':
                        self.bar['value'] = ev[2]
                        self.tree.set(str(ev[1]), 'status', '%.0f%%' % ev[2])
                        self.speed.configure(text='%s   ETA %s' % (ev[3], ev[4]))
                    elif ev[0] == 'file':
                        self.files[ev[1]] = ev[2]
                    elif ev[0] == 'log':
                        self.write_log(ev[1])
                    elif ev[0] == 'finished':
                        self.busy = False
                        self.go.configure(state='normal')
            except queue.Empty:
                pass
            self.after(100, self.poll)

    app = App()
    if shot:   # debugging aid: screenshot this window, then quit
        def take():
            subprocess.run(['screencapture', '-x', shot])
            app.destroy()
        app.after(3500, take)
    elif smoke:
        app.after(1500, app.destroy)
    app.mainloop()
    if smoke:
        print('UI SMOKE OK')


# ---------------------------------------------------------------- self-test (run: python3 yt_gui.py --selftest)
def selftest():
    n = [0, 0]

    def eq(a, b, m):
        n[0 if a == b else 1] += 1
        if a != b:
            print('FAIL', m, a, '!=', b)

    eq(valid_url('https://a.com/x'), True, 'https ok')
    eq(valid_url('http://a.com'), True, 'http ok')
    eq(valid_url('--exec=rm'), False, 'option-like rejected')
    eq(valid_url('file:///etc/passwd'), False, 'file scheme rejected')
    eq(valid_url('https://a.com/x y'), False, 'space rejected')
    eq(format_for('audio', '720'), 'bestaudio[ext=m4a]/bestaudio/best', 'audio fmt')
    eq(format_for('video', 'best'), 'b[ext=mp4]/b', 'video best')
    eq(format_for('video', '480'), 'b[height<=480][ext=mp4]/b[height<=480]/b', 'video 480')
    c = build_cmd(['yt-dlp'], 'https://a.com/v', 'video', '720', '/tmp/x', False, ('node', '/n'))
    eq(format_for('video', '720', '/f/ffmpeg'), 'bv*[height<=720]+ba/b[height<=720]/b', 'merge fmt with ffmpeg')
    eq(format_for('video', 'best', '/f'), 'bv*+ba/b', 'merge best')
    cf = build_cmd(['y'], 'https://a', 'video', '720', '/t', False, None, '/f/ffmpeg')
    eq(cf[cf.index('--ffmpeg-location') + 1], '/f/ffmpeg', 'ffmpeg location passed')
    eq('--ffmpeg-location' in build_cmd(['y'], 'https://a', 'audio', '720', '/t', False, None, '/f'), False, 'no ffmpeg flag for audio')
    eq('--ffmpeg-location' in c, False, 'no ffmpeg flag without ffmpeg')
    eq(c[c.index('--extractor-args') + 1], 'youtube:player_client=default,mweb', 'mweb client added without ffmpeg')
    eq('--extractor-args' in cf, False, 'no client override when ffmpeg merges')
    eq('--extractor-args' in build_cmd(['y'], 'https://a', 'audio', '720', '/t', False, None), False, 'no client override for audio')
    eq(c[0], 'yt-dlp', 'base first')
    eq(c[-2:], ['--', 'https://a.com/v'], 'url after --')
    eq('--no-playlist' in c, True, 'no playlist default')
    eq(c[c.index('--js-runtimes') + 1], 'node:/n', 'js runtime')
    eq('-x' in c or '--extract-audio' in c, False, 'never converts audio')
    eq('--yes-playlist' in build_cmd(['y'], 'https://a', 'audio', '720', '/t', True, None), True, 'playlist flag')
    eq('--js-runtimes' in build_cmd(['y'], 'https://a', 'audio', '720', '/t', True, None), False, 'no js flag when none')
    eq(parse_line('PROG| 45.3%|1.2MiB/s|00:03'), ('prog', 45.3, '1.2MiB/s', '00:03'), 'progress')
    eq(parse_line('PROG|  N/A|Unknown|Unknown') is None, True, 'unknown progress ignored')
    eq(parse_line('FILE|/tmp/a b.mp4'), ('file', '/tmp/a b.mp4'), 'file')
    eq(parse_line('ERROR: [youtube] x: Sign in to confirm')[0], 'err', 'error')
    eq(parse_line('[download] Destination: x') is None, True, 'other lines ignored')
    eq(parse_line('\x1b[0;32mPROG| 10.0%|1MiB/s|00:01\x1b[0m')[0], 'prog', 'ansi stripped')

    # Spotify
    eq(parse_spotify_link('https://open.spotify.com/track/3z8h0TU7ReDPLIbEnYhWZb?si=abc'), ('track', '3z8h0TU7ReDPLIbEnYhWZb'), 'track link')
    eq(parse_spotify_link('https://open.spotify.com/intl-fr/album/0ETFjACtuP2ADo6LFhL6HN'), ('album', '0ETFjACtuP2ADo6LFhL6HN'), 'intl album link')
    eq(parse_spotify_link('spotify:playlist:37i9dQZF1DXcBWIGoYBM5M'), ('playlist', '37i9dQZF1DXcBWIGoYBM5M'), 'uri')
    eq(parse_spotify_link('https://open.spotify.com/artist/3z8h0TU7ReDPLIbEnYhWZb'), None, 'artist not supported')
    eq(parse_spotify_link('https://evil.com/?u=https://open.spotify.com/track/3z8h0TU7ReDPLIbEnYhWZb'), None, 'must start with spotify')
    eq(is_spotify_address('https://spotify.link/xyz'), True, 'spotify short link')
    eq(is_spotify_address('https://notspotify.com/x'), False, 'lookalike host')
    page = ('<html><script id="__NEXT_DATA__" type="application/json">' + json.dumps({'props': {'pageProps': {'state': {'data': {'entity': {
        'type': 'album', 'name': 'Abbey Road', 'visualIdentity': {'image': [{'url': 'https://c/ab67616d00001e02abc', 'maxWidth': 300}, {'url': 'https://c/ab67616d00004851abc', 'maxWidth': 64}]},
        'trackList': [{'title': 'Come Together', 'subtitle': 'The Beatles', 'duration': 259946, 'uri': 'spotify:track:2Eql'}, {'title': 'Something', 'subtitle': 'The Beatles', 'duration': 182000}, {'subtitle': 'no title'}]}}}}}}) + '</script></html>')
    al = parse_spotify_entity(spotify_entity(page))
    eq(al['name'], 'Abbey Road', 'album name')
    eq(al['collection'], True, 'album is collection')
    eq([t['title'] for t in al['tracks']], ['Come Together', 'Something'], 'album tracks')
    eq([t['album'] for t in al['tracks']], ['Abbey Road', 'Abbey Road'], 'album on tracks')
    eq([t['number'] for t in al['tracks']], [1, 2], 'track numbers')
    eq(al['tracks'][0]['total'], 2, 'track total')
    eq(al['tracks'][0]['art_url'], 'https://c/ab67616d0000b273abc', 'art upgraded to 640 px')
    eq(al['tracks'][0]['spotify_id'], '2Eql', 'spotify id')
    one = parse_spotify_entity({'type': 'track', 'name': 'Bohemian Rhapsody', 'duration': 354947, 'id': 'TID', 'artists': [{'name': 'Queen'}, {'name': 'Other'}],
                                'releaseDate': {'isoString': '2018-10-19T00:00:00Z'}, 'visualIdentity': {'image': [{'url': 'https://c/ab67616d00001e02zz', 'maxWidth': 300}]}})
    eq(one['tracks'][0], new_track('Bohemian Rhapsody', 'Queen, Other', 354947, '', '2018', 'https://c/ab67616d0000b273zz', 0, 0, 'TID'), 'single track')
    pl = parse_spotify_entity({'type': 'playlist', 'name': 'Mix', 'visualIdentity': {'image': [{'url': 'https://c/ab67616d00001e02pp', 'maxWidth': 300}]},
                               'trackList': [{'title': 'A', 'subtitle': 'B', 'duration': 1000, 'uri': 'spotify:track:XYZ'}]})
    eq(pl['tracks'][0]['art_url'], '', 'playlist picture is not song art')
    eq(pl['tracks'][0]['album'], '', 'no album name for playlist songs')
    eq(spotify_entity('<html>nothing</html>') is None, True, 'no data page')
    eq(parse_spotify_entity({'type': 'playlist', 'name': 'x', 'trackList': []}) is None, True, 'empty list')
    eq(safe_file_name('AC/DC: Back In Black?'), 'AC DC Back In Black', 'safe name')
    eq(safe_file_name('...'), 'Spotify', 'empty safe name')
    t = new_track('100% Pure', 'Queen', 200000)

    def cmd(src, cands=None, tr=None):
        return build_track_cmd(['y'], tr or t, src, cands or [], '/t', None)

    def flt(c):
        return c[c.index('--match-filter') + 1] if '--match-filter' in c else None
    eq(cmd('lyric')[-2:], ['--', 'ytsearch10:Queen 100% Pure lyrics'], 'lyric search')
    eq(flt(cmd('lyric')), 'duration>=190 & duration<=210 & title~=(?i)lyric & title!~=(?i)\\b(cover|karaoke|live|remix|instrumental|reaction|slowed|sped up|nightcore|8d|mashup)\\b', 'lyric filter')
    eq(cmd('official')[-2:], ['--', 'ytsearch10:Queen 100% Pure official video'], 'official search')
    eq(flt(cmd('official')).startswith('duration>=180 & duration<=220 & title~=(?i)official'), True, 'official filter has a wider window')
    eq(cmd('musicvideo')[-2:], ['--', 'ytsearch10:Queen 100% Pure music video'], 'music video search')
    eq('title~=(?i)official' in flt(cmd('musicvideo')), False, 'music video tier does not need official')
    eq(cmd('top')[-2:], ['--', 'ytsearch1:Queen 100% Pure'], 'top result')
    eq(flt(cmd('top')), None, 'no filter for the top result')
    eq(cmd('ytmusic', ['https://www.youtube.com/watch?v=aaaaaaaaaaa'])[-2:], ['--', 'https://www.youtube.com/watch?v=aaaaaaaaaaa'], 'YT Music downloads from the listed songs only')
    eq(flt(cmd('ytmusic', ['u'])), 'duration>=190 & duration<=210', 'YT Music duration window')
    eq(cmd('top')[cmd('top').index('-o') + 1], 'Queen - 100%% Pure.%(ext)s', 'percent escaped in file name')
    eq(cmd('top')[cmd('top').index('-f') + 1], 'bestaudio[ext=m4a]/bestaudio/best', 'songs prefer m4a')
    eq(cmd('top')[cmd('top').index('--max-downloads') + 1], '1', 'max one download')
    live = new_track('Live and Let Die', 'Paul McCartney', 190000)
    eq('|live|' in exclusion_filter(live), False, 'a song called Live is not excluded for live')
    eq('cover' in exclusion_filter(live), True, 'other words still excluded')
    nodur = new_track('X', '', 0)
    eq(flt(cmd('ytmusic', ['u'], nodur)), None, 'no length known: no length filter')
    eq(cmd('top', None, nodur)[-2:], ['--', 'ytsearch1:X'], 'no artist')
    eq(ytmusic_search_url(t), 'https://music.youtube.com/search?q=Queen%20100%25%20Pure', 'YT Music search address')
    eq(percent_encode_query('a&b+c'), 'a%26b%2Bc', 'query encoding')
    listing = 'https://music.youtube.com/watch?v=BSTsnWoslP4\nhttps://music.youtube.com/browse/UCEPMVbUzImPl4p8k4LkGevA\nhttps://music.youtube.com/browse/MPREb_9hHD965Z9xx\nhttps://music.youtube.com/watch?v=646p-BvYvpg\nhttps://music.youtube.com/watch?v=BSTsnWoslP4\nNA'
    eq(watch_links(listing), ['https://www.youtube.com/watch?v=BSTsnWoslP4', 'https://www.youtube.com/watch?v=646p-BvYvpg'], 'only song links, no artists or albums, no repeats')
    eq(len(watch_links(listing, 1)), 1, 'listing limit')
    eq([k for k, _ in SOURCES], ['ytmusic', 'lyric', 'official', 'musicvideo', 'top'], 'search order')
    eq(format_for('audio', '720', None, 'best'), 'bestaudio/best', 'best audio format')
    logs = []
    jobs = plan_jobs(['https://a.com/v', '--exec=bad', 'https://open.spotify.com/artist/3z8h0TU7ReDPLIbEnYhWZb'], '/base', logs.append)
    eq([j['label'] for j in jobs], ['https://a.com/v'], 'plan keeps plain links only')
    eq(len(logs), 2, 'plan explains skipped lines')


    # music search (Apple / Deezer)
    eq(parse_catalog_line('itunes:album:1441164426 # The Beatles - Abbey Road'), ('itunes', 'album', '1441164426'), 'album line')
    eq(parse_catalog_line('ITUNES:SONG:55'), ('itunes', 'song', '55'), 'song line, any case')
    eq(parse_catalog_line('deezer:playlist:9 #x'), ('deezer', 'playlist', '9'), 'playlist line')
    eq(parse_catalog_line('itunes:artist:1'), None, 'artist lines are only for browsing')
    eq(parse_catalog_line('https://itunes:album:1'), None, 'must start the line')
    eq(parse_catalog_line('itunes:album:12x'), None, 'id is digits only')
    eq(big_art('https://x/100x100bb.jpg'), 'https://x/1000x1000bb.jpg', '1000 px art')
    song = {'kind': 'song', 'trackId': 11, 'trackName': 'Chazak!', 'artistName': 'Avraham Fried', 'collectionName': 'Chazak!', 'trackNumber': 1, 'trackCount': 11,
            'trackTimeMillis': 269000, 'releaseDate': '2010-01-01T08:00:00Z', 'artworkUrl100': 'https://x/100x100bb.jpg'}
    tk_ = itunes_track(song)
    eq((tk_['title'], tk_['number'], tk_['total'], tk_['year'], tk_['art_url'], tk_['duration_ms']), ('Chazak!', 1, 11, '2010', 'https://x/1000x1000bb.jpg', 269000), 'song fields')
    sh = itunes_song_hits({'results': [song, {'kind': 'music-video', 'trackId': 12, 'trackName': 'v'}, {'wrapperType': 'artist'}]})
    eq(len(sh), 1, 'only songs in song hits')
    eq(hit_line(sh[0]), 'itunes:song:11 # Avraham Fried - Chazak!', 'song line label')
    eq(sh[0]['detail'], 'Chazak! · 2010 · 4:29', 'song detail')
    albums = {'results': [
        {'wrapperType': 'artist', 'artistName': 'Queen'},
        {'wrapperType': 'collection', 'collectionId': 1, 'collectionName': 'Abbey Road', 'artistName': 'The Beatles', 'trackCount': 17, 'releaseDate': '1969-09-26T07:00:00Z'},
        {'wrapperType': 'collection', 'collectionId': 2, 'collectionName': 'Abbey Road (Deluxe Edition)', 'artistName': 'The Beatles', 'trackCount': 40, 'releaseDate': '2019-09-27T07:00:00Z'},
        {'wrapperType': 'collection', 'collectionId': 3, 'collectionName': 'Abbey Road - Remastered', 'artistName': 'The Beatles', 'trackCount': 17, 'releaseDate': '2009-09-09T07:00:00Z'},
        {'wrapperType': 'collection', 'collectionId': 4, 'collectionName': 'Help! - EP', 'artistName': 'The Beatles', 'trackCount': 4, 'releaseDate': '1965-08-06T07:00:00Z'},
        {'wrapperType': 'collection', 'collectionId': 5, 'collectionName': 'Empty', 'artistName': 'The Beatles', 'trackCount': 0, 'releaseDate': '1970-01-01T07:00:00Z'}]}
    eq([h['id'] for h in folded_album_hits(albums)], ['itunes:album:2', 'itunes:album:4'], 'editions folded (largest kept), empty dropped, newest first')
    eq(folded_album_name('Abbey Road (Remastered 2009)'), 'abbey road', 'fold brackets')
    eq(folded_album_name('Abbey Road - Single'), 'abbey road', 'fold single suffix')
    eq(folded_album_name('Hineni'), 'hineni', 'plain name')
    eq(folded_album_name('שיר'), 'שיר', 'Hebrew letters are kept')
    pl = deezer_playlist_hits({'data': [{'id': 5, 'title': 'Jewish Wedding Dance', 'nb_tracks': 5, 'user': {'name': 'DJ'}}, {'title': 'no id'}]})
    eq((len(pl), hit_line(pl[0]), pl[0]['detail']), (1, 'deezer:playlist:5 # DJ - Jewish Wedding Dance', '5 songs'), 'playlist hit')
    dt = deezer_track({'title': 'Dance', 'duration': 200, 'artist': {'name': 'Band'}, 'album': {'title': 'LP', 'cover_xl': 'https://x/xl.jpg'}})
    eq((dt['duration_ms'], dt['album'], dt['art_url']), (200000, 'LP', 'https://x/xl.jpg'), 'deezer track')
    eq(itunes_artist_hits({'results': [{'artistId': 9, 'artistName': 'ישי ריבו', 'primaryGenreName': 'Pop'}]})[0]['id'], 'itunes:artist:9', 'artist hit')
    # catalog lines flow through the planner (with the network faked)
    real_fc = fetch_catalog
    alb = {'name': 'Abbey Road', 'collection': True, 'tracks': [new_track('A', 'B', 1000, album='Abbey Road', number=1, total=3), new_track('C', 'B', 2000, album='Abbey Road', number=2, total=3), new_track('D', 'B', 3000, album='Abbey Road', number=3, total=3)]}
    globals()['fetch_catalog'] = lambda ref: (alb, '') if ref == ('itunes', 'album', '77') else (None, 'nope')
    try:
        jobs = plan_jobs(['itunes:album:77 # B - Abbey Road'], '/base', lambda m: None, lambda lst: [2, 0])
        eq([j['label'] for j in jobs], ['B - A', 'B - D'], 'catalog album: only the chosen songs')
        eq(jobs[0]['folder'], os.path.join('/base', 'Abbey Road'), 'album goes into its own folder')
        logs2 = []
        eq(plan_jobs(['itunes:album:99'], '/base', logs2.append), [], 'unknown album gives no jobs')
        eq(len(logs2), 1, 'unknown album is explained')
    finally:
        globals()['fetch_catalog'] = real_fc
    # picking songs from an album
    real_fetch = fetch_spotify
    fake = {'name': 'Abbey Road', 'collection': True, 'tracks': [new_track('A', 'B', 1000), new_track('C', 'B', 2000), new_track('D', 'B', 3000)]}
    globals()['fetch_spotify'] = lambda kind, sid: (fake, '')
    try:
        link = 'https://open.spotify.com/album/0ETFjACtuP2ADo6LFhL6HN'
        seen = []
        jobs = plan_jobs([link], '/base', lambda m: None, lambda lst: seen.append(lst['name']) or [2, 0])
        eq([j['label'] for j in jobs], ['B - A', 'B - D'], 'only the chosen songs, in album order')
        eq(seen, ['Abbey Road'], 'chooser was asked once')
        eq(len(plan_jobs([link], '/base', lambda m: None, lambda lst: [])), 0, 'nothing chosen skips the album')
        eq(len(plan_jobs([link], '/base', lambda m: None, None)), 3, 'no chooser: all songs')
        eq(len(plan_jobs([link], '/base', lambda m: None, lambda lst: [0, 99])), 1, 'out-of-range picks ignored')
        fake_single = {'name': 'One', 'collection': False, 'tracks': [new_track('A', 'B', 1000)]}
        globals()['fetch_spotify'] = lambda kind, sid: (fake_single, '')
        eq(len(plan_jobs(['https://open.spotify.com/track/3z8h0TU7ReDPLIbEnYhWZb'], '/base', lambda m: None, lambda lst: [])), 1, 'a single song is never asked about')
    finally:
        globals()['fetch_spotify'] = real_fetch

    # tag writer on a synthetic MP4 (header first, audio data after it, with a chunk-offset table that must move)
    def mp4(mdat_first):
        mdat = _box(b'mdat', b'AUDIO-BYTES-' * 20)
        def moov_for(off):
            stbl = _box(b'stbl', _box(b'stco', struct.pack('>IIII', 0, 2, off, off + 50)))
            trak = _box(b'trak', _box(b'mdia', _box(b'minf', stbl)))
            return _box(b'moov', _box(b'mvhd', b'\x00' * 100) + trak + _box(b'udta', _box(b'free', b'old')))
        ftyp = _box(b'ftyp', b'M4A \x00\x00\x00\x00M4A mp42isom')
        if mdat_first:
            return ftyp + mdat + moov_for(len(ftyp) + 8), len(ftyp) + 8
        size = len(moov_for(0))
        return ftyp + moov_for(len(ftyp) + size + 8) + mdat, len(ftyp) + size + 8
    tr = new_track('Come Together', 'The Beatles', 259000, 'Abbey Road', '1969', '', 1, 17)
    art = b'\xff\xd8\xff\xe0' + b'J' * 2000
    for mdat_first in (False, True):
        src, first_chunk = mp4(mdat_first)
        out = tag_m4a_bytes(src, tr, art)
        tops = {k: (s, e, h) for k, s, e, h in _boxes(out, 0, len(out))}
        ms, me, mh = tops[b'moov']
        eq(b'ilst' in out and b'Come Together' in out and b'Abbey Road' in out and b'\xa9day' in out and b'trkn' in out and b'covr' in out, True, 'tags present (mdat_first=%s)' % mdat_first)
        eq(b'old' in out, False, 'old udta replaced')
        eq(out[tops[b'mdat'][0]:tops[b'mdat'][1]], src[[s for k, s, e, h in _boxes(src, 0, len(src)) if k == b'mdat'][0]:[e for k, s, e, h in _boxes(src, 0, len(src)) if k == b'mdat'][0]], 'audio data untouched')
        new_first = tops[b'mdat'][0] + 8
        i = out.index(b'stco') + 4
        _count, off1, off2 = struct.unpack_from('>III', out, i + 4)
        eq((off1, off2), (new_first, new_first + 50), 'chunk offsets still point at the audio (mdat_first=%s)' % mdat_first)
        eq(out[off1:off1 + 12], b'AUDIO-BYTES-', 'offset lands on the audio bytes')
    try:
        tag_m4a_bytes(b'not an mp4 file at all....', tr, None)
        eq(True, False, 'non-mp4 should fail')
    except ValueError:
        eq(True, True, 'non-mp4 rejected')
    f = find_ytdlp()
    eq(f is None or isinstance(f, list), True, 'find_ytdlp type')
    ff = find_ffmpeg()
    eq(ff is None or isinstance(ff, str), True, 'find_ffmpeg type')
    j = find_js()
    eq(j is None or (len(j) == 2 and j[0] in ('node', 'deno')), True, 'find_js type')
    print('%d passed, %d failed' % tuple(n))
    return n[1] == 0


if __name__ == '__main__':
    if '--selftest' in sys.argv:
        sys.exit(0 if selftest() else 1)
    if '--search' in sys.argv:   # --search <song|album|artist|playlist> <words...> [--albums]   (prints the results; opens no window)
        a = sys.argv[sys.argv.index('--search') + 1:]
        kind, words = a[0], [w for w in a[1:] if w != '--albums']
        hits, err = search_catalog(kind, ' '.join(words))
        if kind == 'artist' and hits and '--albums' in sys.argv:
            print('artist: ' + hits[0]['title'])
            hits, err = artist_albums(hits[0]['id'].split(':')[-1])
        if err:
            print('error: ' + err)
        for h in hits:
            print(' | '.join((h['id'], h['title'], h['subtitle'], h['detail'])))
        sys.exit(0)
    if '--download' in sys.argv:   # headless check: python3 yt_gui.py --download <url> <folder> <audio|video>
        a = [x for x in sys.argv[sys.argv.index('--download') + 1:] if x != '--tiers' and ',' not in x and x not in [k for k, _ in SOURCES]] if '--tiers' in sys.argv else sys.argv[sys.argv.index('--download') + 1:]
        q = queue.Queue()
        d = Downloader(q)
        if '--tiers' in sys.argv:   # test only: --tiers ytmusic,lyric,official,musicvideo,top
            d.sources = sys.argv[sys.argv.index('--tiers') + 1].split(',')
        d.start(find_ytdlp(), [a[0]], a[2] if len(a) > 2 else 'video', '720', a[1], False, find_js(), find_ffmpeg(), 'm4a')
        while True:
            ev = q.get()
            print(ev)
            if ev[0] == 'finished':
                break
        sys.exit(0)
    shot_path = sys.argv[sys.argv.index('--shot') + 1] if '--shot' in sys.argv else None
    main(smoke='--smoke' in sys.argv, shot=shot_path)
