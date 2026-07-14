#shellcheck shell=sh

# Tests for the [[ ... ]] conditional expression construct.
# Each case runs a [[ ]] test and echoes Y on success (exit 0) / N on failure,
# mirroring bash/zsh semantics.

Describe '[[ ]] conditional expression'
  zish() {
    ./zig-out/bin/zish -c "$1"
  }

  Describe 'boolean composition'
    It 'evaluates && (both true)'
      When call zish '[[ -z "" && -n x ]] && echo Y || echo N'
      The output should equal "Y"
    End

    It 'short-circuits && (first false)'
      When call zish '[[ -n "" && -n x ]] && echo Y || echo N'
      The output should equal "N"
    End

    It 'evaluates || (second true)'
      When call zish '[[ 1 == 2 || 2 == 2 ]] && echo Y || echo N'
      The output should equal "Y"
    End

    It 'gives && higher precedence than ||'
      When call zish '[[ 1 == 2 || 3 == 3 && 4 == 4 ]] && echo Y || echo N'
      The output should equal "Y"
    End

    It 'negates a sub-expression'
      When call zish '[[ ! -f /nonexistent ]] && echo Y || echo N'
      The output should equal "Y"
    End

    It 'negates a parenthesized group'
      When call zish '[[ ! ( 1 == 2 ) ]] && echo Y || echo N'
      The output should equal "Y"
    End
  End

  Describe 'parenthesized grouping'
    It 'groups an || under a &&'
      When call zish '[[ ( 1 == 1 || 2 == 3 ) && 3 == 3 ]] && echo Y || echo N'
      The output should equal "Y"
    End

    It 'group changes result vs flat precedence'
      When call zish '[[ ( 1 == 2 || 3 == 3 ) && 1 == 2 ]] && echo Y || echo N'
      The output should equal "N"
    End
  End

  Describe 'pattern matching'
    It 'treats unquoted RHS of == as a glob'
      When call zish '[[ abcd == a* ]] && echo Y || echo N'
      The output should equal "Y"
    End

    It 'treats quoted RHS of == as a literal'
      When call zish '[[ abcd == "a*" ]] && echo Y || echo N'
      The output should equal "N"
    End

    It 'matches ? and char classes'
      When call zish '[[ foo == f[aeiou]o ]] && echo Y || echo N'
      The output should equal "Y"
    End

    It 'negates a pattern with !='
      When call zish '[[ abcd != x* ]] && echo Y || echo N'
      The output should equal "Y"
    End
  End

  Describe 'regex =~'
    It 'matches anchored digit regex'
      When call zish '[[ 12345 =~ ^[0-9]+$ ]] && echo Y || echo N'
      The output should equal "Y"
    End

    It 'fails when regex does not match'
      When call zish '[[ abc =~ ^[0-9]+$ ]] && echo Y || echo N'
      The output should equal "N"
    End

    It 'matches unanchored substring'
      When call zish '[[ abc123 =~ [0-9]+ ]] && echo Y || echo N'
      The output should equal "Y"
    End
  End

  Describe 'string ordering'
    It 'orders with <'
      When call zish '[[ abc < abd ]] && echo Y || echo N'
      The output should equal "Y"
    End

    It 'orders with >'
      When call zish '[[ abd > abc ]] && echo Y || echo N'
      The output should equal "Y"
    End
  End

  Describe 'numeric comparison'
    It 'compares with -gt'
      When call zish '[[ 5 -gt 3 ]] && echo Y || echo N'
      The output should equal "Y"
    End

    It 'combines numeric comparisons'
      When call zish '[[ 5 -gt 3 && 2 -lt 1 ]] && echo Y || echo N'
      The output should equal "N"
    End
  End

  Describe 'unary operators'
    It '-z on empty string is true'
      When call zish '[[ -z "" ]] && echo Y || echo N'
      The output should equal "Y"
    End

    It '-n on non-empty string is true'
      When call zish '[[ -n x ]] && echo Y || echo N'
      The output should equal "Y"
    End

    It '-v detects a set variable'
      When call zish 'V=1; [[ -v V ]] && echo Y || echo N'
      The output should equal "Y"
    End

    It '-v is false for an unset variable'
      When call zish '[[ -v UNSET_XYZ ]] && echo Y || echo N'
      The output should equal "N"
    End

    It '-o detects an enabled shell option'
      When call zish 'set -e; [[ -o errexit ]] && echo Y || echo N'
      The output should equal "Y"
    End
  End

  Describe 'as a control condition'
    It 'works inside if'
      When call zish 'if [[ 1 == 1 ]]; then echo Y; else echo N; fi'
      The output should equal "Y"
    End

    It 'works inside while'
      When call zish 'i=0; while [[ $i -lt 3 ]]; do echo $i; i=$((i+1)); done'
      The output should equal "0
1
2"
    End
  End
End
