# Deploys Relay/ to Convex prod: `npx convex deploy` insists on a TTY, so answer its prompt through a pty.
# usage: python3 scripts/deploy-prod.py <path to Relay>
import os, pty, sys, time, select
cwd = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd)
    os.execvp("npx", ["npx", "convex", "deploy", "--typecheck", "enable"])
out = b""
answered = False
deadline = time.time() + 300
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 1)
    if fd in r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
        if not answered and (b"(y/N)" in out or b"(Y/n)" in out or b"push" in out.lower() and b"?" in chunk):
            os.write(fd, b"y\n")
            answered = True
    _, status = os.waitpid(pid, os.WNOHANG)
    if _ == pid:
        break
text = out.decode(errors="replace")
import re
text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)
print("\n".join(line for line in text.splitlines() if line.strip())[-1500:])
