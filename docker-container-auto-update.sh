#!/usr/bin/env bash
set -e

# modify values
BASE_IMAGE="image"
REGISTRY="registry"
IMAGE="$REGISTRY/$BASE_IMAGE"

cd $(dirname $0)
CID=$(docker ps | grep $IMAGE | awk '{print $1}')
docker pull $IMAGE

for im in $CID
do
    LATEST=`docker inspect --format "{{.Id}}" $IMAGE`
    RUNNING=`docker inspect --format "{{.Image}}" $im`
    NAME=`docker inspect --format '{{.Name}}' $im | sed "s/\///g"`
    echo "Latest:" $LATEST
    echo "Running:" $RUNNING
    if [ "$RUNNING" != "$LATEST" ];then
        echo "upgrading $IMAGE"
        docker-compose up -d --force-recreate
        docker image prune -f
    else
        echo "$IMAGE up to date"
    fi
done
