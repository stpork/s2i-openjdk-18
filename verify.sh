#!/bin/bash

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

check_jar_signature $1

exit $?
