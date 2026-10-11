#!/usr/bin/env python3
"""yt-dlp GUI: a small window for downloading video or audio with yt-dlp (Mac and Windows, standard library only).

ffmpeg is optional. Without it, video comes as one ready-made file with the sound already in it (the best single-file
quality the site offers; some sites, YouTube included, no longer offer one) and audio comes as m4a/webm without
conversion. With ffmpeg found, video is joined from the best picture and sound. It only runs yt-dlp on your links.
"""
import glob
import importlib.util
import json
import os
import queue
import re
import shutil
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


def format_for(mode, height, ffmpeg=None):
    if mode == 'audio':
        return 'bestaudio[ext=m4a]/bestaudio/best'
    if ffmpeg:   # picture and sound are joined by ffmpeg
        if height == 'best':
            return 'bv*+ba/b'
        return 'bv*[height<=%s]+ba/b[height<=%s]/b' % (height, height)
    if height == 'best':
        return 'b[ext=mp4]/b'
    return 'b[height<=%s][ext=mp4]/b[height<=%s]/b' % (height, height)


NEEDS_FFMPEG = ('That site only offers the picture and the sound as separate streams (YouTube does this now), '
                'and joining them needs ffmpeg. Audio only still works without it.')


def build_cmd(base, url, mode, height, folder, playlist, js, ffmpeg=None):
    cmd = list(base) + [
        '--newline', '--no-quiet', '--no-colors', '--windows-filenames',
        '-P', folder, '-o', '%(title).100s.%(ext)s',
        '--progress-template', 'download:PROG|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s',
        '--print', 'after_move:FILE|%(filepath)s',
        '--yes-playlist' if playlist else '--no-playlist',
        '-f', format_for(mode, height, ffmpeg)]
    if ffmpeg and mode == 'video':
        cmd += ['--ffmpeg-location', ffmpeg, '--merge-output-format', 'mp4']
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


class Downloader:
    """Runs the links one after another on a background thread and reports through a queue."""

    def __init__(self, events):
        self.events = events
        self.proc = None
        self.cancelled = False

    def start(self, base, urls, mode, height, folder, playlist, js, ffmpeg=None):
        self.cancelled = False
        threading.Thread(target=self._run, args=(base, urls, mode, height, folder, playlist, js, ffmpeg), daemon=True).start()

    def stop(self):
        self.cancelled = True
        p = self.proc
        if p and p.poll() is None:
            try:
                p.terminate()
            except Exception:
                pass

    def _run(self, base, urls, mode, height, folder, playlist, js, ffmpeg=None):
        flags = subprocess.CREATE_NO_WINDOW if IS_WIN else 0
        for i, url in enumerate(urls):
            if self.cancelled:
                self.events.put(('row', i, 'Cancelled'))
                continue
            self.events.put(('row', i, 'Starting...'))
            err, last_file = '', ''
            try:
                self.proc = subprocess.Popen(build_cmd(base, url, mode, height, folder, playlist, js, ffmpeg),
                                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
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
                code, err = 1, 'could not run yt-dlp: %s' % e
            if self.cancelled:
                self.events.put(('row', i, 'Cancelled'))
            elif code == 0:
                self.events.put(('row', i, 'Done'))
            else:
                self.events.put(('row', i, 'Failed'))
                why = err or 'yt-dlp stopped with an error (exit code %s)' % code
                if mode == 'video' and not ffmpeg and 'Requested format is not available' in why:
                    why = NEEDS_FFMPEG
                self.events.put(('log', '%s\n  %s' % (url, why)))
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
def main(smoke=False):
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
            self.playlist = tk.BooleanVar(value=bool(s.get('playlist', False)))
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
            box = ttk.Frame(self)
            box.pack(fill='x', padx=12)
            self.links = tk.Text(box, height=5, wrap='none', undo=True)
            self.links.pack(side='left', fill='x', expand=True)
            ttk.Button(box, text='Paste', command=self.paste).pack(side='left', padx=(8, 0), anchor='n')

            row = ttk.Frame(self)
            row.pack(fill='x', **pad)
            ttk.Radiobutton(row, text='Video', variable=self.mode, value='video', command=self.mode_changed).pack(side='left')
            ttk.Radiobutton(row, text='Audio only', variable=self.mode, value='audio', command=self.mode_changed).pack(side='left', padx=(10, 16))
            ttk.Label(row, text='Max height').pack(side='left')
            self.height_box = ttk.Combobox(row, textvariable=self.height, values=HEIGHTS, width=6, state='readonly')
            self.height_box.pack(side='left', padx=(6, 16))
            ttk.Checkbutton(row, text='Whole playlist', variable=self.playlist).pack(side='left')

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
            if not video:
                msg = 'Audio is saved as it comes from the site (usually .m4a), with no conversion.'
            elif self.ffmpeg:
                msg = 'ffmpeg found: video is joined from the best picture and sound, up to the height you choose.'
            else:
                msg = 'No ffmpeg: video is saved as one file with sound in it, the best single-file quality the site offers. YouTube no longer offers one, so use Audio only there.'
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
            raw = [l.strip() for l in self.links.get('1.0', 'end').splitlines() if l.strip()]
            urls = [u for u in raw if valid_url(u)]
            bad = [u for u in raw if not valid_url(u)]
            if bad:
                self.write_log('Skipped (not an http/https link): ' + ', '.join(b[:60] for b in bad))
            if not urls:
                messagebox.showinfo('yt-dlp', 'Paste at least one link that starts with http:// or https://')
                return
            if len(urls) > MAX_LINKS:
                self.write_log('Only the first %d links are used.' % MAX_LINKS)
                urls = urls[:MAX_LINKS]
            folder = os.path.expanduser(self.folder.get().strip() or DEFAULT_FOLDER)
            try:
                os.makedirs(folder, exist_ok=True)
            except OSError as e:
                messagebox.showerror('Save to', 'Cannot use that folder: %s' % e)
                return
            save_settings({'mode': self.mode.get(), 'height': self.height.get(), 'playlist': self.playlist.get(), 'folder': folder})
            self.tree.delete(*self.tree.get_children())
            self.files = {}
            for i, u in enumerate(urls):
                self.tree.insert('', 'end', iid=str(i), values=(u, 'Waiting'))
            self.busy = True
            self.go.configure(state='disabled')
            self.bar['value'] = 0
            self.dl.start(self.base, urls, self.mode.get(), self.height.get(), folder, self.playlist.get(), self.js, self.ffmpeg)

        def poll(self):
            try:
                while True:
                    ev = self.events.get_nowait()
                    if ev[0] == 'row':
                        self.tree.set(str(ev[1]), 'status', ev[2])
                        if ev[2] in ('Done', 'Failed', 'Cancelled'):
                            self.bar['value'] = 100 if ev[2] == 'Done' else 0
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
    if smoke:
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
    if '--download' in sys.argv:   # headless check: python3 yt_gui.py --download <url> <folder> <audio|video>
        a = sys.argv[sys.argv.index('--download') + 1:]
        q = queue.Queue()
        d = Downloader(q)
        d.start(find_ytdlp(), [a[0]], a[2] if len(a) > 2 else 'video', '720', a[1], False, find_js(), find_ffmpeg())
        while True:
            ev = q.get()
            print(ev)
            if ev[0] == 'finished':
                break
        sys.exit(0)
    main(smoke='--smoke' in sys.argv)
