FROM daewok/lisp-devel:ql

WORKDIR /home/lisp/quicklisp/local-projects/image-classifier

COPY . .

ARG CREDS
ARG PICTURES

ENV IC_API_CREDS=$CREDS
ENV IC_PICTURE_ROOT=$PICTURES

WORKDIR /
RUN sbcl --load /home/lisp/quicklisp/local-projects/image-classifier/install-docker.lisp --non-interactive --quit

EXPOSE 5000
CMD ./app
