import websocket, sys, time, os
# Set DE10_IP to your MiSTer's address, e.g. DE10_IP=192.168.1.x python3 ws_send.py kbd:enter
url="ws://%s:8182/api/ws" % os.environ["DE10_IP"]
ws=websocket.create_connection(url, timeout=5)
ws.settimeout(0.5)
# drain greeting
try:
    while True: ws.recv()
except Exception: pass
for msg in sys.argv[1:]:
    ws.send(msg)
    print("SENT:", msg)
    time.sleep(0.15)
time.sleep(0.3)
ws.close()
