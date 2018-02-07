#!/bin/sh

# Fail on a single failed command
set -eo pipefail

if [ "${SCRIPT_DEBUG}" = "true" ] ; then
    set -x
    echo "Script debugging is enabled, allowing bash commands and their arguments to be printed as they are executed"
fi

# ==========================================================
# Generic run script for running arbitrary Java applications
#
# Source and Documentation can be found
# at https://github.com/fabric8io/run-java-sh
#
# ==========================================================

# Error is indicated with a prefix in the return value
check_error() {
  local msg=$1
  if echo ${msg} | grep -q "^ERROR:"; then
    echo ${msg}
    exit 1
  fi
}

# The full qualified directory where this script is located
get_script_dir() {
  # Default is current directory
  local dir=`dirname "$0"`
  local full_dir=`cd "${dir}" ; pwd`
  echo ${full_dir}
}

# Try hard to find a sane default jar-file
auto_detect_jar_file() {
  local dir=$1

  # Filter out temporary jars from the shade plugin which start with 'original-'
  local old_dir=$(pwd)
  cd ${dir}
  if [ $? = 0 ]; then
    local nr_jars=`ls *.jar 2>/dev/null | grep -v '^original-' | wc -l | tr -d '[[:space:]]'`
    if [ ${nr_jars} = 1 ]; then
      ls *.jar | grep -v '^original-'
      exit 0
    fi

    echo >&2 "ERROR: Neither \$JAVA_MAIN_CLASS nor \$JAVA_APP_JAR is set and ${nr_jars} JARs found in ${dir} (1 expected)"
	echo >&2 $(pwd && ls -la && la -la /deployments)
    cd ${old_dir}
  else
    echo >&2 "ERROR: No directory ${dir} found for auto detection"
  fi
}

# Check directories (arg 2...n) for a jar file (arg 1)
get_jar_file() {
  local jar=$1
  shift;

  if [ "${jar:0:1}" = "/" ]; then
    if [ -f "${jar}" ]; then
      echo "${jar}"
    else
      echo >&2 "ERROR: No such file ${jar}"
    fi
  else
    for dir in $*; do
      if [ -f "${dir}/$jar" ]; then
        echo "${dir}/$jar"
        return
      fi
    done
    echo >&2 "ERROR: No ${jar} found in $*"
  fi
}

load_env() {
  local script_dir=$1

  # Configuration stuff is read from this file
  local run_env_sh="run-env.sh"

  # Load default default config
  if [ -f "${script_dir}/${run_env_sh}" ]; then
    source "${script_dir}/${run_env_sh}"
  fi

  # Check also $JAVA_APP_DIR. Overrides other defaults
  # It's valid to set the app dir in the default script
  if [ -z "${JAVA_APP_DIR}" ]; then
    JAVA_APP_DIR="${script_dir}"
  else
    if [ -f "${JAVA_APP_DIR}/${run_env_sh}" ]; then
      source "${JAVA_APP_DIR}/${run_env_sh}"
    fi
  fi
  export JAVA_APP_DIR

  # Read in container limits and export the as environment variables
  if [ -f "${script_dir}/container-limits" ]; then
    source "${script_dir}/container-limits"
  fi

  # JAVA_LIB_DIR defaults to JAVA_APP_DIR
  export JAVA_LIB_DIR="${JAVA_LIB_DIR:-${JAVA_APP_DIR}}"
  if [ -z "${JAVA_MAIN_CLASS}" ] && [ -z "${JAVA_APP_JAR}" ]; then
    JAVA_APP_JAR="$(auto_detect_jar_file ${JAVA_APP_DIR})"
    check_error "${JAVA_APP_JAR}"
  fi

  if [ "x${JAVA_APP_JAR}" != x ]; then
    local jar="$(get_jar_file ${JAVA_APP_JAR} ${JAVA_APP_DIR} ${JAVA_LIB_DIR})"
    check_error "${jar}"
    export JAVA_APP_JAR=${jar}
  else
    export JAVA_MAIN_CLASS
  fi
}

# Check for standard /opt/run-java-options first, fallback to run-java-options in the path if not existing
run_java_options() {
  if [ -f "/opt/run-java-options" ]; then
    echo `sh /opt/run-java-options`
  else
    which run-java-options >/dev/null 2>&1
    if [ $? = 0 ]; then
      echo `run-java-options`
    fi
  fi
}

# Combine all java options
get_java_options() {
  local dir=$(get_script_dir)
  local java_opts
  local debug_opts
  if [ -f "$dir/java-default-options" ]; then
    java_opts=$($dir/java-default-options)
  fi
  if [ -f "$dir/debug-options" ]; then
    debug_opts=$($dir/debug-options)
  fi
  if [ -f "$dir/proxy-options" ]; then
    source "$dir/proxy-options"
    proxy_opts="$(proxy_options)"
  fi
  # Normalize spaces with awk (i.e. trim and elimate double spaces)
  echo "${JAVA_OPTIONS} $(run_java_options) ${debug_opts} ${proxy_opts} ${java_opts}" | awk '$1=$1'
}

# Read in a classpath either from a file with a single line, colon separated
# or given line-by-line in separate lines
# Arg 1: path to claspath (must exist), optional arg2: application jar, which is stripped from the classpath in
# multi line arrangements
format_classpath() {
  local cp_file="$1"
  local app_jar="$2"

  local wc_out=`wc -l $1 2>&1`
  if [ $? -ne 0 ]; then
    echo "Cannot read lines in ${cp_file}: $wc_out"
    exit 1
  fi

  local nr_lines=`echo $wc_out | awk '{ print $1 }'`
  if [ ${nr_lines} -gt 1 ]; then
    local sep=""
    local classpath=""
    while read file; do
      local full_path="${JAVA_LIB_DIR}/${file}"
      # Don't include app jar if include in list
      if [ x"${app_jar}" != x"${full_path}" ]; then
        classpath="${classpath}${sep}${full_path}"
      fi
      sep=":"
    done < "${cp_file}"
    echo "${classpath}"
  else
    # Supposed to be a single line, colon separated classpath file
    cat "${cp_file}"
  fi
}

# Fetch classpath from env or from a local "run-classpath" file
get_classpath() {
  local cp_path="."
  if [ "x${JAVA_LIB_DIR}" != "x${JAVA_APP_DIR}" ]; then
    cp_path="${cp_path}:${JAVA_LIB_DIR}"
  fi
  if [ -z "${JAVA_CLASSPATH}" ] && [ "x${JAVA_MAIN_CLASS}" != x ]; then
    if [ "x${JAVA_APP_JAR}" != x ]; then
      cp_path="${cp_path}:${JAVA_APP_JAR}"
    fi
    if [ -f "${JAVA_LIB_DIR}/classpath" ]; then
      # Classpath is pre-created and stored in a 'run-classpath' file
      cp_path="${cp_path}:`format_classpath ${JAVA_LIB_DIR}/classpath ${JAVA_APP_JAR}`"
    else
      # No order implied
      cp_path="${cp_path}:${JAVA_APP_DIR}/*"
    fi
  elif [ "x${JAVA_CLASSPATH}" != x ]; then
    # Given from the outside
    cp_path="${JAVA_CLASSPATH}"
  fi
  echo "${cp_path}"
}

# Set process name if possible
get_exec_args() {
  EXEC_ARGS=""
  if [ "x${JAVA_APP_NAME}" != x ]; then
    # Not all shells support the 'exec -a newname' syntax..
    `exec -a test true 2>/dev/null`
    if [ "$?" = 0 ] ; then
      echo "-a '${JAVA_APP_NAME}'"
    else
      # Lets switch to bash if you have it installed...
      if [ -f "/bin/bash" ] ; then
        exec "/bin/bash" $0 $@
      fi
    fi
  fi
}

check_jar_signature() {
DEV=Development
TEST=Testing
PRE=Staging
PROD=Production
CN="- Signed by \"CN="
DN=$DEVOPS_DNAME
ENV=' Environment'
OK='jar verified.'
INVALID="is not property signed for deployment"

if [[ "$DEVOPS_DPENV" != "DEV" && "$DEVOPS_DPENV" != "TEST" && "$DEVOPS_DPENV" != "PRE" && "$DEVOPS_DPENV" != "PROD" ]]; then
  echo Cannot determine deployment environment for $1!
  return 10
fi

D=0 && T=0 && S=0 && P=0 && O=0

while read line; do
  E=$?
  [[ "$line" == "$CN$DEV$ENV$DN\"" ]] && D=1; 
  [[ "$line" == "$CN$TEST$ENV$DN\"" ]] && T=1; 
  [[ "$line" == "$CN$PRE$ENV$DN\"" ]] && S=1; 
  [[ "$line" == "$CN$PROD$ENV$DN\"" ]] && P=1; 
  [[ "$line" == "$OK" ]] && O=1;
done <<< $(jarsigner -verify -verbose $1)

[ ! $E -eq 0 ] && echo Package $1 is corrupted! && return 9
[ ! $O -eq 1 ] && echo Package $1 is unsigned! && return 5

if [[ "$DEVOPS_DPENV" == "DEV" && $D != 1 ]]; then 
  echo Package $1 $INVALID to $DEV$ENV! 
  return 1
fi;

if [[ "$DEVOPS_DPENV" == "TEST" && ($D != 1 || $T != 1) ]]; then 
  echo Package $1 $INVALID to $TEST$ENV!
  return 2
fi;

if [[ "$DEVOPS_DPENV" == "PRE"  && ($D != 1 || $T != 1 || $S != 1) ]]; then 
  echo Package $1 $INVALID to $PRE$ENV!
  return 3
fi;

if [[ "$DEVOPS_DPENV" == "PROD" && ($D != 1 || $T != 1 || $S != 1 || $P != 1) ]]; then 
  echo Package $1 $INVALID to $PROD$ENV!
  return 4
fi;

return 0
}

# Start JVM
startup() {
  # Initialize environment
  load_env $(get_script_dir)

  local args
  cd ${JAVA_APP_DIR}
  if [ "x${JAVA_MAIN_CLASS}" != x ] ; then
     args="${JAVA_MAIN_CLASS}"
  else
     args="-jar ${JAVA_APP_JAR}"
     check_jar_signature ${JAVA_APP_JAR}
     [ ! $? -eq 0 ] && exit $?
  fi

  echo exec $(get_exec_args) java $(get_java_options) -cp "$(get_classpath)" ${args} $*
  exec $(get_exec_args) java $(get_java_options) -cp "$(get_classpath)" ${args} $*
}

# =============================================================================
# Fire up
startup $*
