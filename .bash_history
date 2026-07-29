PS1="<\u@\H:\w>\$ "
echo M1
exit
n=0
PROMPT_COMMAND='n=$((n+1)); echo PC$n'
echo cmd1
echo cmd2
exit
PROMPT_COMMAND='echo HI'
echo a
echo b
exit
PROMPT_COMMAND='echo HI'
echo a
echo b
exit
PROMPT_COMMAND='echo [hook]'
echo one
echo two
exit
