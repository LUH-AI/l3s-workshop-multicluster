FROM python:3.12-slim
WORKDIR /app
COPY gateway.py .
ENV PYTHONUNBUFFERED=1 PORT=8080
EXPOSE 8080
USER 65534
CMD ["python", "gateway.py"]
