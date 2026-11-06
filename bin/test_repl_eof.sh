#!/bin/sh
# Regression test: the REPL exits 0 on stdin EOF, and only the REPL's own read treats
# EOF specially (a program reading (stinput) still sees -1 / "error: empty stream").
# Usage: bin/test_repl_eof.sh   (EOF_DEADLINE seconds per case, default 120)
HERE="$(cd "$(dirname "$0")/.." && pwd)"
deadline=${EOF_DEADLINE:-120}; fails=0; tmp=$(mktemp -d)
check() { # label input must-contain must-not-contain
  printf "$2" > "$tmp/in"
  timeout "$deadline" "$HERE/bin/shen" < "$tmp/in" > "$tmp/out" 2>&1; rc=$?
  v=ok; [ "$rc" = 0 ] || v="exit=$rc"
  [ "$v" = ok ] && [ -n "$3" ] && ! grep -qF -- "$3" "$tmp/out" && v="missing '$3'"
  [ "$v" = ok ] && [ -n "$4" ] && grep -qF -- "$4" "$tmp/out" && v="contains '$4'"
  if [ "$v" = ok ]; then echo "PASS  $1"; else echo "FAIL  $1: $v"; fails=$((fails+1)); fi
}
check "empty stdin exits"            ''                        ''            'empty stream'
check "unterminated last line runs"  '(+ 40 2)'                '42'          'empty stream'
check "multi-line form runs"         '(+ 40\n2)'               '42'          'empty stream'
check "program read-byte gets -1"    '(read-byte (stinput))\n' '-1'          ''
check "program read: empty stream"   '(read (stinput))\n'     'empty stream' ''
rm -rf "$tmp"; echo "failures=$fails"; exit $fails
