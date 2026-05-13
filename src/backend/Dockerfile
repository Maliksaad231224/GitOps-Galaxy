FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .

# --timeout 120  : wait up to 2 min per read (default is 15s — too short on Vagrant)
# --retries 5    : retry failed connections 5 times before giving up
# --no-cache-dir : keep image small
RUN pip install --no-cache-dir --timeout 120 --retries 5 -r requirements.txt

COPY app.py .

EXPOSE 5000
CMD ["python", "app.py"]