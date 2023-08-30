docker run -it --rm -v/home/yfeng/server/pytorch/pytorch_backend:/pytorch_backend -v /var/run/docker.sock:/var/run/docker.sock tritonserver_buildbase bash

cd /pytorch_backend/build
cmake -DCMAKE_INSTALL_PREFIX:PATH=`pwd`/install -DTRITON_PYTORCH_DOCKER_IMAGE="nvcr.io/nvidia/pytorch:23.04-py3" ..
make -j 10
