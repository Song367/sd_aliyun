FROM alpine/git:2.36.2 as download

COPY clone.sh /clone.sh

RUN . /clone.sh taming-transformers https://github.com/CompVis/taming-transformers.git 24268930bf1dce879235a7fddd0b2355b84d7ea6 \
  && rm -rf data assets **/*.ipynb

RUN . /clone.sh stable-diffusion-stability-ai https://github.com/Stability-AI/stablediffusion.git cf1d67a6fd5ea1aa600c4df58e5b47da45f6bdbf \
  && rm -rf assets data/**/*.png data/**/*.jpg data/**/*.gif

RUN . /clone.sh generative-models https://github.com/Stability-AI/generative-models.git 45c443b316737a4ab6e40413d7794a7f5657c19f

RUN . /clone.sh CodeFormer https://github.com/sczhou/CodeFormer.git c5b4593074ba6214284d6acd5f1719b6c5d739af \
  && rm -rf assets inputs

RUN . /clone.sh BLIP https://github.com/salesforce/BLIP.git 48211a1594f1321b00f14c9f7a5b4813144b2fb9
RUN . /clone.sh k-diffusion https://github.com/crowsonkb/k-diffusion.git ab527a9a6d347f364e3d185ba6d714e22d80cb3c
RUN . /clone.sh clip-interrogator https://github.com/pharmapsychotic/clip-interrogator 2486589f24165c8e3b303f84e9dbbea318df83e8


FROM alpine:3.17 as xformers
RUN apk add --no-cache aria2
RUN aria2c -x 5 --dir / --out wheel.whl 'https://github.com/AbdBarho/stable-diffusion-webui-docker/releases/download/6.0.0/xformers-0.0.21.dev544-cp310-cp310-manylinux2014_x86_64-pytorch201.whl'

FROM python:3.10.9-slim as extensions

RUN --mount=type=cache,target=/root/.cache/pip \
    pip install transformers[sentencepiece] sentencepiece && \
    pip install torch==2.0.1 torchvision==0.15.2 --index-url https://download.pytorch.org/whl/cu118

COPY ./init /init
RUN mkdir -p /clip-vit-large-patch14 && python /init/clip-vit-large-patch14.py /clip-vit-large-patch14

FROM python:3.10.9-slim as  sd_base

ENV DEBIAN_FRONTEND=noninteractive PIP_PREFER_BINARY=1

RUN --mount=type=cache,target=/var/cache/apt \
  apt-get update && \
  # we need those
  apt-get install -y fonts-dejavu-core rsync git jq moreutils aria2 \
  # extensions needs those
  ffmpeg libglfw3-dev libgles2-mesa-dev pkg-config libcairo2 libcairo2-dev


RUN --mount=type=cache,target=/cache --mount=type=cache,target=/root/.cache/pip \
  aria2c -x 5 --dir /cache --out torch-2.0.1-cp310-cp310-linux_x86_64.whl -c \
  https://download.pytorch.org/whl/cu118/torch-2.0.1%2Bcu118-cp310-cp310-linux_x86_64.whl && \
  pip install /cache/torch-2.0.1-cp310-cp310-linux_x86_64.whl torchvision --index-url https://download.pytorch.org/whl/cu118 && \
  pip install transformers==4.30.2 

RUN --mount=type=cache,target=/root/.cache/pip \
  git clone https://github.com/Song367/stable-diffusion-webui.git && \
  cd stable-diffusion-webui && git checkout master && \
  pip install -r requirements_versions.txt

RUN --mount=type=cache,target=/root/.cache/pip  \
  --mount=type=bind,from=xformers,source=/wheel.whl,target=/xformers-0.0.21.dev544-cp310-cp310-manylinux2014_x86_64.whl \
  pip install /xformers-0.0.21.dev544-cp310-cp310-manylinux2014_x86_64.whl

ENV ROOT=/stable-diffusion-webui


COPY --from=download /repositories/ ${ROOT}/repositories/
RUN mkdir ${ROOT}/interrogate && cp ${ROOT}/repositories/clip-interrogator/data/* ${ROOT}/interrogate
RUN --mount=type=cache,target=/root/.cache/pip \
  pip install -r ${ROOT}/repositories/CodeFormer/requirements.txt

RUN --mount=type=cache,target=/root/.cache/pip \
  pip install pyngrok \
  git+https://github.com/TencentARC/GFPGAN.git@8d2447a2d918f8eba5a4a01463fd48e45126a379 \
  git+https://github.com/openai/CLIP.git@d50d76daa670286dd6cacf3bcd80b5e4823fc8e1 \
  git+https://github.com/mlfoundations/open_clip.git@bb6e834e9c70d9c27d0dc3ecedeebeaeb1ffad6b

# Note: don't update the sha of previous versions because the install will take forever
# instead, update the repo state in a later step

# TODO: either remove if fixed in A1111 (unlikely) or move to the top with other apt stuff
RUN apt-get -y install libgoogle-perftools-dev && apt-get clean
ENV LD_PRELOAD=libtcmalloc.so


RUN --mount=type=cache,target=/root/.cache/pip \
  cd stable-diffusion-webui && ls && \
  git fetch && \
  pip install -r requirements_versions.txt
RUN apt-get install -y wget
# RUN cd ${ROOT}/models/Stable-diffusion && wget https://huggingface.co/casque/majicmixRealistic_v7/resolve/main/majicmixRealistic_v7.safetensors
COPY . /docker

FROM sd_base as base

ENV SD_BUILTIN=/built-in
COPY ./sd-resource ${SD_BUILTIN}
RUN cp -R ${ROOT}/scripts ${SD_BUILTIN}/scripts && \
    cp -R ${ROOT}/extensions-builtin/* ${SD_BUILTIN}/extensions-builtin/

COPY --from=extensions /clip-vit-large-patch14  ${SD_BUILTIN}/root/.cache/huggingface/hub/
# RUN \
#   python3 /docker/info.py ${ROOT}/modules/ui.py && \
#   mv ${ROOT}/style.css ${ROOT}/user.css && \
#   # one of the ugliest hacks I ever wrote \
#   sed -i 's/in_app_dir = .*/in_app_dir = True/g' /usr/local/lib/python3.10/site-packages/gradio/routes.py && \
#   git config --global --add safe.directory '*'

WORKDIR ${ROOT}
# ENV NVIDIA_VISIBLE_DEVICES=all
# ENV CLI_ARGS="--xformers  --disable-safe-unpickle --no-half-vae --enable-insecure-extension-access --skip-version-check --no-download-sd-model "
# EXPOSE 7860
# RUN chmod +x /docker/entrypoint.sh
# ENTRYPOINT ["/docker/entrypoint.sh"]
# CMD python launch.py --listen --api --port 7860 --precision full --no-half ${CLI_ARGS}


ENV NVIDIA_VISIBLE_DEVICES=all
ENV CLI_ARGS="--xformers  --disable-safe-unpickle --no-half-vae --enable-insecure-extension-access --skip-version-check --no-download-sd-model"
EXPOSE 7860
RUN chmod +x /docker/entrypoint.sh
ENTRYPOINT ["/docker/entrypoint.sh"]
CMD python -u webui.py --listen --port 7860 ${CLI_ARGS}
