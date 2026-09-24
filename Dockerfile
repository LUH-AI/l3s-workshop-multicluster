# 3.10, not the latest - SMAC/PyExperimenter (see requirements.txt,
# WP3 Component 2/3) are most reliably compatible with 3.10; newer
# versions risk dependency resolution issues with SMAC's own pinned deps.
FROM python:3.10-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/
COPY version.txt .

ARG GIT_SHA=unknown
ENV GIT_SHA=${GIT_SHA}
LABEL org.opencontainers.image.revision=${GIT_SHA}
LABEL org.opencontainers.image.source="https://github.com/org/project"

CMD ["python", "src/hello.py"]
