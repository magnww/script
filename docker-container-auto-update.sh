#!/usr/bin/env bash
set -e

# modify values
BASE_IMAGE="image"
REGISTRY="registry"
SERVICE_NAME="service"
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
        systemctl stop $SERVICE_NAME
        docker-compose up --no-start --force-recreate
        systemctl start $SERVICE_NAME
        docker image prune -f
    else
        echo "$IMAGE up to date"
    fi
done
