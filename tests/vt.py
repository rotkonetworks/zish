"""Minimal VT emulator: enough to know where the cursor actually is."""
import re
class VT:
    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.g = [[" "]*cols for _ in range(rows)]
        self.r = self.c = 0
    def _clampc(self):
        if self.c < 0: self.c = 0
        if self.c > self.cols: self.c = self.cols
        if self.r < 0: self.r = 0
        if self.r >= self.rows: self.r = self.rows-1
    def scroll(self):
        """Real terminals scroll when content passes the last row."""
        self.g.pop(0); self.g.append([" "]*self.cols); self.r = self.rows-1

    def newline(self):
        if self.r >= self.rows-1: self.scroll()
        else: self.r += 1

    def put(self, ch):
        if self.c >= self.cols:          # deferred wrap: wrap on the next write
            self.c = 0; self.newline()
        self.g[self.r][self.c] = ch; self.c += 1
    def feed(self, s):
        i = 0
        while i < len(s):
            ch = s[i]
            if ch == "\x1b":
                m = re.match(r"\x1b\[([0-9;?]*)([A-Za-z])", s[i:])
                if m:
                    p, cmd = m.group(1), m.group(2)
                    n = int(p) if p.isdigit() and p else 1
                    if   cmd=="A": self.r -= n
                    elif cmd=="B":
                        for _ in range(n): self.newline()
                    elif cmd=="C": self.c += n
                    elif cmd=="D": self.c -= n
                    elif cmd=="G": self.c = (int(p) if p else 1)-1
                    elif cmd=="H":
                        pr=p.split(";"); self.r=(int(pr[0]) if pr[0] else 1)-1
                        self.c=(int(pr[1]) if len(pr)>1 and pr[1] else 1)-1
                    elif cmd=="J":
                        mode = int(p) if p else 0
                        if mode==0:
                            for cc in range(self.c,self.cols): self.g[self.r][cc]=" "
                            for rr in range(self.r+1,self.rows): self.g[rr]=[" "]*self.cols
                        elif mode==2:
                            self.g=[[" "]*self.cols for _ in range(self.rows)]
                    elif cmd=="K":
                        for cc in range(self.c,self.cols): self.g[self.r][cc]=" "
                    self._clampc(); i += m.end(); continue
                m2 = re.match(r"\x1b\][^\x07]*\x07|\x1b[=>()][A-Za-z0-9]?", s[i:])
                if m2: i += m2.end(); continue
                i += 1; continue
            if ch == "\r": self.c = 0
            elif ch == "\n": self.newline()
            elif ch == "\b": self.c = max(0, self.c-1)
            elif ch == "\x07": pass
            else: self.put(ch)
            i += 1
    def line(self, r): return "".join(self.g[r]).rstrip()
    def screen(self): return [self.line(r) for r in range(self.rows)]

    def visible_text(self):
        """All non-blank rows joined — what a human can actually read."""
        return "\n".join(l for l in self.screen() if l.strip())
