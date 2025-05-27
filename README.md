# TL;DR

- `git clone https://github.com/adderek/dozzle-swarm-test.git` to clone repo
- `git submodule init ; git submodule update` to update submodules
- `cd dozzle-swarm-test` to enter repo directory
- `docker compose up -d` to start docker swarm
- open http://localhost:8080/dozzle/ to see dozzle manager
- `docker compose down --remove-orphans` to stop docker swarm

# Commands help

## We are using docker compose (v2, that is docker-compose-plugin) to start docker swarm nodes with docker-in-docker (dind)

- `docker compose up -d` to start docker swarm
- `docker compose down --remove-orphans` to stop docker swarm
- `docker compose logs` to see logs
- `docker compose ps` to see status
- `docker compose exec manager docker node ls` to see nodes
- `docker compose exec manager docker stack ls` to see stacks
- `docker compose exec manager docker service ls` to see services
- `docker compose exec manager docker stack deploy -c swarm/docker-stack.yml dozzle` to deploy dozzle
- `docker compose exec manager docker stack rm dozzle` to remove dozzle
- `docker compose exec manager docker stack ps dozzle` to see dozzle stack status

### For full system cleanup:

- `docker compose down --remove-orphans`
- `docker rm -f $(docker ps -aq)`
- `docker volume rm $(docker volume ls -q)`
- `docker network rm $(docker network ls -q --filter name=swarm)`
- `docker system prune -af --volumes`

# Introduction

## Docker compose

There are high odds that you are not familiar with docker compose. This paragraph is an rough introduction to docker compose.

Docker compose runs/stops/manages multiple containers with single command.

Originally docker compose was a separate tool "docker-compose", but it was merged into docker in version 2 "docker compose".

Directory name that contains docker-compose.yml is called project name. Containers names are project name + service name.

## Docker swarm

Docker swarm is like docker compose but on multiple machines called nodes. In our case we simulate multiple machines with docker-in-docker (dind).

## Dozzle

Dozzle is a lightweight logs viewer for docker containers supporting kubernetes, docker swarm and much more.

## Purpose

This repository was created to change, build and test dozzle in docker swarm setup on a single machine.

# Usage

`docker compose watch` to start docker swarm and watch for source changes.

`docker compose down --remove-orphans` to stop docker swarm.

# Explanation

- `docker compose watch` starts docker swarm in DIND and watches for source changes so we can develop them and automatically rebuild and redeploy
- docker swarm runs inside DIND (docker-in-docker) containers 
- dozzle has 2 parts:
  - dozzle manager (runs inside manager node)
  - dozzle agents (inside every worker node)
- http://localhost:8080 opens web interface of dozzle manager which can present logs from all containers in docker swarm
- dozzle agents collect logs from all containers in their node and send them to dozzle manager
