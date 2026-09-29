# mapper image. On cluster B it is converted to /shared/images/mapper.sif and run
# by Apptainer; Docker is only used to build it.
FROM python:3.12-slim
WORKDIR /app
COPY mapper.py .
ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["python", "/app/mapper.py"]
