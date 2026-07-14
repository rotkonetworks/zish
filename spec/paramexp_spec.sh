#shellcheck shell=sh

Describe 'parameter expansion and quoting'
  zish() {
    ./zig-out/bin/zish -c "$1"
  }

  Describe 'default / alternate / assign / error'
    It 'uses value when set (:-)'
      When call zish 'x=hello; echo ${x:-def}'
      The output should equal "hello"
    End
    It 'uses default when unset (:-)'
      When call zish 'echo ${x:-def}'
      The output should equal "def"
    End
    It 'uses default when unset, non-colon (-)'
      When call zish 'x=; echo ${x-def}'
      The output should equal ""
    End
    It 'assigns default (:=)'
      When call zish 'echo ${x:=A}; echo $x'
      The output should equal "A
A"
    End
    It 'alternate when set (:+)'
      When call zish 'x=v; echo ${x:+alt}'
      The output should equal "alt"
    End
    It 'no alternate when empty (:+)'
      When call zish 'x=; echo ${x:+alt}'
      The output should equal ""
    End
  End

  Describe 'length and substring'
    It 'string length'
      When call zish 'x=hello; echo ${#x}'
      The output should equal "5"
    End
    It 'substring offset'
      When call zish 'x=hello; echo ${x:1}'
      The output should equal "ello"
    End
    It 'substring offset and length'
      When call zish 'x=hello; echo ${x:1:2}'
      The output should equal "el"
    End
    It 'negative offset with space'
      When call zish 'x=hello; echo ${x: -2}'
      The output should equal "lo"
    End
    It 'parenthesized negative offset'
      When call zish 'x=hello; echo ${x:(-2)}'
      The output should equal "lo"
    End
    It 'negative length'
      When call zish 'x=hello; echo ${x:1:-1}'
      The output should equal "ell"
    End
  End

  Describe 'prefix / suffix removal'
    It 'shortest prefix'
      When call zish 'x=aXbXc; echo ${x#*X}'
      The output should equal "bXc"
    End
    It 'longest prefix'
      When call zish 'x=aXbXc; echo ${x##*X}'
      The output should equal "c"
    End
    It 'shortest suffix'
      When call zish 'x=aXbXc; echo ${x%X*}'
      The output should equal "aXb"
    End
    It 'longest suffix'
      When call zish 'x=aXbXc; echo ${x%%X*}'
      The output should equal "a"
    End
  End

  Describe 'pattern substitution'
    It 'replaces first match'
      When call zish 'x=aa; echo ${x/a/b}'
      The output should equal "ba"
    End
    It 'replaces all matches'
      When call zish 'x=aa; echo ${x//a/b}'
      The output should equal "bb"
    End
    It 'anchors at start'
      When call zish 'x=abcabc; echo ${x/#abc/X}'
      The output should equal "Xabc"
    End
    It 'anchors at end'
      When call zish 'x=abcabc; echo ${x/%abc/X}'
      The output should equal "abcX"
    End
  End

  Describe 'case modification'
    It 'uppercases first char'
      When call zish 'x=hello; echo ${x^}'
      The output should equal "Hello"
    End
    It 'uppercases all'
      When call zish 'x=hello; echo ${x^^}'
      The output should equal "HELLO"
    End
    It 'lowercases first char'
      When call zish 'x=HELLO; echo ${x,}'
      The output should equal "hELLO"
    End
    It 'lowercases all'
      When call zish 'x=HELLO; echo ${x,,}'
      The output should equal "hello"
    End
  End

  Describe 'special parameters'
    It 'positional count $#'
      When call zish 'set -- a b c; echo $#'
      The output should equal "3"
    End
    It 'all params $@'
      When call zish 'set -- a b c; echo $@'
      The output should equal "a b c"
    End
    It 'all params $*'
      When call zish 'set -- a b c; echo $*'
      The output should equal "a b c"
    End
    It 'braced count ${#}'
      When call zish 'set -- a b c; echo ${#}'
      The output should equal "3"
    End
    It 'multi-digit positional ${10}'
      When call zish 'set -- 1 2 3 4 5 6 7 8 9 10; echo ${10}'
      The output should equal "10"
    End
    It 'exit code after failure'
      When call zish 'false; echo $?'
      The output should equal "1"
    End
  End

  Describe 'quoting'
    It 'adjacent concatenation with variable'
      When call zish 'x=B; echo a"$x"c'
      The output should equal "aBc"
    End
    It 'leading quoted variable then literal'
      When call zish 'x=B; echo "$x"c'
      The output should equal "Bc"
    End
    It 'variable followed by space in double quotes'
      When call zish 'x=B; echo "a$x b"'
      The output should equal "aB b"
    End
    It 'braced variable in double quotes'
      When call zish 'x=B; echo "${x}y"'
      The output should equal "By"
    End
    It 'single quotes are literal'
      When call zish "echo 'a\$x'"
      The output should equal 'a$x'
    End
    It 'escaped dollar outside quotes is literal'
      When call zish 'printf "%s" \$x'
      The output should equal '$x'
    End
    It 'escaped dollar inside double quotes is literal'
      When call zish 'printf "%s" "a\$b"'
      The output should equal 'a$b'
    End
  End

  Describe 'ANSI-C quoting'
    It 'decodes tab'
      When call zish "printf '[%s]' \$'a\\tb'"
      The output should equal "[a	b]"
    End
    It 'decodes hex escape'
      When call zish "printf '[%s]' \$'\\x41'"
      The output should equal "[A]"
    End
    It 'decodes octal escape'
      When call zish "printf '[%s]' \$'\\101'"
      The output should equal "[A]"
    End
  End
End
