ARG GALAXY_BASE_IMAGE=quay.io/bgruening/galaxy:26.0
FROM ${GALAXY_BASE_IMAGE}

ENV GALAXY_CONFIG_ADMIN_USERS=admin@example.org \
    GALAXY_CONFIG_BOOTSTRAP_ADMIN_API_KEY=local-usegalaxy-admin-key \
    GALAXY_DEFAULT_ADMIN_EMAIL=admin@example.org \
    GALAXY_DEFAULT_ADMIN_USER=admin@example.org \
    GALAXY_DEFAULT_ADMIN_PASSWORD=password \
    GALAXY_DEFAULT_ADMIN_KEY=fakekey \
    GALAXY_CONFIG_BRAND="Local Galaxy Bioinformatics"

COPY tool_list.yml /tmp/tool_list.yml

RUN install-tools /tmp/tool_list.yml && \
    if [ -x /tool_deps/_conda/bin/conda ]; then /tool_deps/_conda/bin/conda clean --all --yes; fi && \
    rm -f /tmp/tool_list.yml

ENV GALAXY_DEFAULT_ADMIN_EMAIL=admin@example.org \
    GALAXY_DEFAULT_ADMIN_USER=admin@example.org \
    GALAXY_DEFAULT_ADMIN_PASSWORD=password \
    GALAXY_DEFAULT_ADMIN_KEY=local-usegalaxy-admin-key

VOLUME ["/export/"]
