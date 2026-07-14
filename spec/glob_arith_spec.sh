#shellcheck shell=sh

Describe 'zish globbing, brace, tilde, arithmetic'
  zish() {
    ./zig-out/bin/zish -c "$1"
  }

  Describe 'arithmetic $(( ))'
    It 'adds'
      When call zish 'echo $((1+2))'
      The output should equal "3"
    End
    It 'respects precedence'
      When call zish 'echo $((2+3*4-1))'
      The output should equal "13"
    End
    It 'modulo'
      When call zish 'echo $((10%3))'
      The output should equal "1"
    End
    It 'exponent is right associative'
      When call zish 'echo $((2**3**2))'
      The output should equal "512"
    End
    It 'comparison'
      When call zish 'echo $((5>=5))'
      The output should equal "1"
    End
    It 'equality'
      When call zish 'echo $((3==3))'
      The output should equal "1"
    End
    It 'logical or'
      When call zish 'echo $((1||0))'
      The output should equal "1"
    End
    It 'bitwise'
      When call zish 'echo $((5|2))'
      The output should equal "7"
    End
    It 'bitwise not'
      When call zish 'echo $((~0))'
      The output should equal "-1"
    End
    It 'shift'
      When call zish 'echo $((1<<4))'
      The output should equal "16"
    End
    It 'ternary true'
      When call zish 'echo $((1?2:3))'
      The output should equal "2"
    End
    It 'ternary false'
      When call zish 'echo $((0?2:3))'
      The output should equal "3"
    End
    It 'parentheses'
      When call zish 'echo $(((2+3)*4))'
      The output should equal "20"
    End
    It 'variable ref without dollar'
      When call zish 'x=5; echo $((x*x))'
      The output should equal "25"
    End
    It 'assignment inside expr'
      When call zish 'echo $((y=3, y*2))'
      The output should equal "6"
    End
    It 'pre-increment'
      When call zish 'x=5; echo $((++x))'
      The output should equal "6"
    End
    It 'post-increment returns old'
      When call zish 'x=5; echo $((x++)); echo $x'
      The output should equal "5
6"
    End
    It 'compound assignment'
      When call zish 'x=10; echo $((x+=5))'
      The output should equal "15"
    End
    It 'hex literal'
      When call zish 'echo $((0xff))'
      The output should equal "255"
    End
    It 'octal literal'
      When call zish 'echo $((010))'
      The output should equal "8"
    End
    It 'arbitrary base'
      When call zish 'echo $((2#1010))'
      The output should equal "10"
    End
    It 'survives division by zero'
      When call zish 'echo $((1/0)); echo after'
      The output should include "after"
      The status should be success
      The stderr should include "division"
    End
  End

  Describe 'brace expansion'
    It 'comma list'
      When call zish 'echo {a,b,c}'
      The output should equal "a b c"
    End
    It 'prefix and suffix'
      When call zish 'echo pre{a,b}post'
      The output should equal "preapost prebpost"
    End
    It 'nested'
      When call zish 'echo {a,{b,c}}'
      The output should equal "a b c"
    End
    It 'numeric range'
      When call zish 'echo {1..5}'
      The output should equal "1 2 3 4 5"
    End
    It 'numeric range with step'
      When call zish 'echo {1..10..2}'
      The output should equal "1 3 5 7 9"
    End
    It 'zero-padded range'
      When call zish 'echo {01..05}'
      The output should equal "01 02 03 04 05"
    End
    It 'descending range'
      When call zish 'echo {5..1}'
      The output should equal "5 4 3 2 1"
    End
    It 'char range'
      When call zish 'echo {a..e}'
      The output should equal "a b c d e"
    End
    It 'char range with step'
      When call zish 'echo {a..z..5}'
      The output should equal "a f k p u z"
    End
  End

  Describe 'tilde expansion'
    It 'bare tilde expands to HOME'
      When call zish 'echo ~'
      The output should equal "$HOME"
    End
    It 'tilde slash path'
      When call zish 'echo ~/x'
      The output should equal "$HOME/x"
    End
    It 'quoted tilde stays literal'
      When call zish 'echo "~"'
      The output should equal "~"
    End
    It 'tilde not at word start stays literal'
      When call zish 'echo a~b'
      The output should equal "a~b"
    End
    It 'unknown user stays literal'
      When call zish 'echo ~no_such_user_xyz'
      The output should equal "~no_such_user_xyz"
    End
  End

  Describe 'pathname globbing'
    setup() {
      GLOBDIR=$(mktemp -d "${TMPDIR:-/tmp}/zishglob.XXXXXX")
      touch "$GLOBDIR/a.txt" "$GLOBDIR/b.txt" "$GLOBDIR/c.log" "$GLOBDIR/.hidden"
    }
    cleanup() { rm -rf "$GLOBDIR"; }
    BeforeAll 'setup'
    AfterAll 'cleanup'

    It 'star matches files'
      When call zish "echo $GLOBDIR/*.txt"
      The output should equal "$GLOBDIR/a.txt $GLOBDIR/b.txt"
    End
    It 'star does not match hidden files'
      When call zish "echo $GLOBDIR/*"
      The output should equal "$GLOBDIR/a.txt $GLOBDIR/b.txt $GLOBDIR/c.log"
    End
    It 'explicit dot matches hidden'
      When call zish "echo $GLOBDIR/.h*"
      The output should equal "$GLOBDIR/.hidden"
    End
    It 'question mark matches one char'
      When call zish "echo $GLOBDIR/?.txt"
      The output should equal "$GLOBDIR/a.txt $GLOBDIR/b.txt"
    End
    It 'char class at word start'
      When call zish "echo $GLOBDIR/[ab].txt"
      The output should equal "$GLOBDIR/a.txt $GLOBDIR/b.txt"
    End
    It 'no match leaves literal pattern'
      When call zish "echo $GLOBDIR/z*"
      The output should equal "$GLOBDIR/z*"
    End
  End
End
