#!/bin/sh

hugo --baseUrl="/"
scp -r -i ~/.ssh/authorized_keys -P 102  ./public/ root@47.100.94.219:/opt/my-blog

git add .
git commit -m $1
git push