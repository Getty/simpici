FROM docker.io/library/perl:5.40-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates docker.io git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/simpici
COPY cpanfile ./
RUN cpanm --notest --installdeps .

COPY bin/ bin/
COPY action/ action/
COPY lib/ lib/
COPY public/ public/
COPY etc/ etc/

ENTRYPOINT ["perl", "-Ilib", "bin/simpicid"]
CMD ["--config", "etc/simpici.example.json"]
