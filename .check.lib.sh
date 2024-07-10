function check {
  result=0
  for p in $@ 
  do
    echo -n "check if $p is available: " 1>&2
    if ! command -v $p &> /dev/null
    then
        echo "ERROR: not found, please install $p" 1>&2
        result=1
    else
        echo "OK!" 1>&2
    fi 
  done
  
  return $result
}