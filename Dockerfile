# Runtime *environment* only - Python + SMAC/PyExperimenter and their
# build deps. The project code is deliberately not baked in: it gets onto
# the clusters separately and is bound into the container at run time
# (e.g. `apptainer exec --bind <repo>:/app ...`, see scripts/job.sh.j2).
# That way the image only changes when this file or requirements.txt
# change - `fab build` tags it with a hash of exactly those two files.

# 3.10, not the latest - SMAC/PyExperimenter (see requirements.txt,
# WP3 Component 2/3) are most reliably compatible with 3.10; newer
# versions risk dependency resolution issues with SMAC's own pinned deps.
FROM python:3.10-slim

# SMAC's random forest requires swig and a C++ compiler at install time.
RUN apt-get update && \
    apt-get install -y --no-install-recommends swig g++ && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt && rm /tmp/requirements.txt

# Where the code is expected to be bound in.
WORKDIR /app

ARG ENV_TAG=unknown
ENV ENV_TAG=${ENV_TAG}
LABEL org.opencontainers.image.version=${ENV_TAG}
LABEL org.opencontainers.image.source="https://github.com/org/project"

# Smoke test for `fab deploy --run`: is the environment usable?
CMD ["python", "-c", "import os, smac, py_experimenter; from importlib.metadata import version; print('environment', os.environ['ENV_TAG'], 'ok - smac', version('smac'), '/ py-experimenter', version('py-experimenter'))"]
