#shellcheck shell=sh

Describe 'zish redirections, here-docs and command substitution'
  zish() {
    ./zig-out/bin/zish -c "$1"
  }

  tmp() {
    printf '%s' "${TMPDIR:-/tmp}/zish_redir_$$_$1"
  }

  Describe 'output redirection'
    It 'redirects builtin echo to a file'
      f=$(tmp o1)
      When call zish "echo hi > $f; cat $f; rm -f $f"
      The output should equal "hi"
    End

    It 'appends with >>'
      f=$(tmp o2)
      When call zish "echo a > $f; echo b >> $f; cat $f; rm -f $f"
      The line 1 of output should equal "a"
      The line 2 of output should equal "b"
    End

    It 'force-truncates with >|'
      f=$(tmp o3)
      When call zish "echo forced >| $f; cat $f; rm -f $f"
      The output should equal "forced"
    End
  End

  Describe 'fd duplication and ordering'
    It 'sends stdout to file with 2>&1 >file (order matters)'
      f=$(tmp o4)
      When call zish "echo hi 2>&1 >$f; cat $f; rm -f $f"
      The output should equal "hi"
    End

    It 'redirects to explicit fd numbers 3>file 1>&3'
      f=$(tmp o5)
      When call zish "echo hi 3>$f 1>&3; cat $f; rm -f $f"
      The output should equal "hi"
    End

    It 'sends both streams with &>file'
      f=$(tmp o6)
      When call zish "ls /no_such_path_xyz &>$f; cat $f; rm -f $f"
      The output should include "No such file"
    End

    It 'sends both streams with >&file'
      f=$(tmp o7)
      When call zish "ls /no_such_path_xyz >&$f; cat $f; rm -f $f"
      The output should include "No such file"
    End
  End

  Describe 'input redirection'
    It 'reads from a file with <'
      f=$(tmp i1)
      When call zish "printf 'line1\nline2\n' > $f; cat < $f; rm -f $f"
      The line 1 of output should equal "line1"
      The line 2 of output should equal "line2"
    End
  End

  Describe 'here-documents'
    It 'passes a plain heredoc body'
      When call zish "$(printf 'cat <<EOF\nalpha\nbeta\nEOF\n')"
      The line 1 of output should equal "alpha"
      The line 2 of output should equal "beta"
    End

    It 'expands variables in an unquoted heredoc (env-set var)'
      # variable must exist before evaluation: assignment on a prior line of the
      # same -c blob is preprocessed before it runs (see report).
      export HDX=WORLD
      When call zish "$(printf 'cat <<EOF\nv=%s\nEOF\n' '$HDX')"
      The output should equal "v=WORLD"
    End

    It 'does not expand a quoted-delimiter heredoc'
      When call zish "$(printf "cat <<'EOF'\nlit \$HOME\nEOF\n")"
      The output should equal 'lit $HOME'
    End

    It 'strips leading tabs with <<-'
      When call zish "$(printf 'cat <<-EOF\n\tindented\n\tEOF\n')"
      The output should equal "indented"
    End
  End

  Describe 'here-strings'
    It 'feeds a literal word'
      When call zish 'cat <<< "a b c"'
      The output should equal "a b c"
    End

    It 'expands a variable in a here-string'
      When call zish 'x=hey; cat <<< $x'
      The output should equal "hey"
    End
  End

  Describe 'command substitution'
    It 'substitutes a simple command'
      When call zish 'echo $(echo hi)'
      The output should equal "hi"
    End

    It 'substitutes nested command substitution'
      When call zish 'echo $(echo $(echo deep))'
      The output should equal "deep"
    End

    It 'expands variables inside substitution'
      When call zish 'x=val; echo $(echo $x)'
      The output should equal "val"
    End

    It 'captures pipeline output in substitution'
      When call zish 'echo $(printf "a\nb\nc\n" | grep b)'
      The output should equal "b"
    End

    It 'supports backtick substitution'
      When call zish 'echo `echo bt`'
      The output should equal "bt"
    End

    It 'strips trailing newlines'
      When call zish 'echo "<$(printf "x\n\n\n")>"'
      The output should equal "<x>"
    End
  End
End
