#shellcheck shell=sh

# NOTE: this sandbox's shellspec mishandles a literal '|' inside the argument
# passed to "When call", so pipe-fed loops are exercised via shellspec's Data
# (stdin) feature instead of an in-string pipe. The underlying behaviour is
# identical: `while read` must terminate at EOF.
Describe 'zish control flow and command lists'
  zish() {
    ./zig-out/bin/zish -c "$1"
  }

  Describe 'while read terminates at EOF (regression)'
    It 'reads every line then stops'
      Data
        #|a
        #|b
        #|c
      End
      When call zish "while read x; do echo got \$x; done"
      The line 1 should eq "got a"
      The line 3 should eq "got c"
      The status should eq 0
    End

    It 'splits into multiple variables on IFS'
      Data "x y z"
      When call zish "read a b; echo \"[\$a][\$b]\""
      The output should eq "[x][y z]"
    End

    It 'strips leading/trailing IFS for a single var'
      Data "  hi   there  "
      When call zish "read a; echo \"[\$a]\""
      The output should eq "[hi   there]"
    End

    It 'read returns non-zero at EOF'
      When call zish "read x; echo \"rc=\$?\""
      The output should eq "rc=1"
    End
  End

  Describe 'if condition grammar'
    It 'allows [[ ]] as condition'
      When call zish "if [[ 1 == 1 ]]; then echo y; fi"
      The output should eq "y"
    End

    It 'allows an and-or list as condition'
      When call zish "if true && true; then echo y; fi"
      The output should eq "y"
    End

    It 'allows a read (command) as condition'
      Data "line"
      When call zish "if read v; then echo \"got:\$v\"; fi"
      The output should eq "got:line"
    End

    It 'allows ! negation as condition'
      When call zish "if ! false; then echo y; fi"
      The output should eq "y"
    End

    It 'handles elif/else chains'
      When call zish 'x=2; if [ $x = 1 ]; then echo one; elif [ $x = 2 ]; then echo two; else echo other; fi'
      The output should eq "two"
    End
  End

  Describe 'pipeline negation'
    It 'negates a simple command to success'
      When call zish "! false; echo \$?"
      The output should eq "0"
    End

    It 'negates a true command to failure'
      When call zish "! true; echo \$?"
      The output should eq "1"
    End
  End

  Describe 'until loop'
    It 'runs the body while the condition is false'
      When call zish "until false; do echo once; break; done"
      The output should eq "once"
    End

    It 'stops once the condition becomes true'
      When call zish 'n=0; until [ $n -ge 3 ]; do echo $n; n=$((n+1)); done'
      The line 1 should eq "0"
      The line 3 should eq "2"
    End
  End

  Describe 'and-or precedence (equal, left-associative)'
    It 'evaluates || then && left to right'
      When call zish "true || false && echo X"
      The output should eq "X"
    End

    It 'short-circuits && then falls through to ||'
      When call zish "false && echo A || echo B"
      The output should eq "B"
    End
  End

  Describe 'break and continue levels'
    It 'break N exits N enclosing loops'
      When call zish 'for i in 1 2 3; do for j in a b; do break 2; done; echo "after $i"; done; echo end'
      The output should eq "end"
    End

    It 'continue N continues an outer loop'
      When call zish 'for i in 1 2 3; do for j in a b c; do if [ $j = b ]; then continue 2; fi; echo "$i$j"; done; done'
      The line 1 should eq "1a"
      The line 3 should eq "3a"
    End

    It 'plain break exits a single loop'
      When call zish 'i=0; while [ $i -lt 5 ]; do i=$((i+1)); if [ $i = 3 ]; then break; fi; echo $i; done'
      The line 1 should eq "1"
      The line 2 should eq "2"
    End
  End

  Describe 'subshell isolation'
    It 'isolates variable assignments'
      When call zish 'x=1; ( x=2 ); echo $x'
      The output should eq "1"
    End

    It 'propagates the subshell exit status'
      When call zish '( exit 3 ); echo $?'
      The output should eq "3"
    End
  End

  Describe 'brace group runs in the current shell'
    It 'keeps variable assignments'
      When call zish 'x=1; { x=2; }; echo $x'
      The output should eq "2"
    End
  End

  Describe 'for without a list iterates positional params'
    It 'parses for x; do ... done'
      When call zish 'for x; do echo hi; done; echo ok'
      The output should include "ok"
    End
  End
End
