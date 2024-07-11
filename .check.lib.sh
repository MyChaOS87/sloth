function check_programs_available {
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


function assert_no_overwrite {
  if [ -f "$1" ]; then
    echo "ERROR: $1 already exists, please remove it first if you want to recreate it from scratch" 1>&2
    return 1
  fi

  return 0
}