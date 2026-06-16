#!/usr/bin/env python3
"""Bridge: reads /dev/ttyUSB0, serves data via TCP on port 9000."""

import os
import socket
import termios
import errno

SERIAL = "/dev/ttyUSB0"
BAUD = 115200
HOST = "0.0.0.0"
PORT = 9000


def configure_serial(fd):
    attrs = termios.tcgetattr(fd)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = attrs

    # Raw mode
    iflag &= ~(termios.BRKINT | termios.INPCK | termios.ISTRIP |
               termios.IXON | termios.IXOFF | termios.IXANY |
               termios.IGNBRK | termios.INLCR | termios.IGNCR | termios.ICRNL)
    oflag &= ~termios.OPOST
    cflag &= ~(termios.CSIZE | termios.PARENB | termios.CSTOPB | termios.CRTSCTS)
    cflag |= termios.CS8 | termios.CREAD | termios.CLOCAL
    lflag &= ~(termios.ICANON | termios.ECHO | termios.ECHOE |
               termios.ECHOK | termios.ECHONL | termios.ISIG | termios.IEXTEN)
    cc[termios.VMIN] = 1
    cc[termios.VTIME] = 0

    # Baud rate
    ispeed = ospeed = BAUD

    termios.tcsetattr(fd, termios.TCSAFLUSH,
                      [iflag, oflag, cflag, lflag, ispeed, ospeed, cc])


def main():
    print(f"[bridge] opening {SERIAL}...")
    fd = os.open(SERIAL, os.O_RDWR | os.O_NOCTTY)
    try:
        print("[bridge] configuring serial...")
        configure_serial(fd)
        termios.tcflush(fd, termios.TCIOFLUSH)

        print(f"[bridge] starting TCP server on {HOST}:{PORT}...")
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((HOST, PORT))
        sock.listen(1)

        print("[bridge] waiting for connection...")
        conn, addr = sock.accept()
        print(f"[bridge] connected: {addr}")

        while True:
            try:
                data = os.read(fd, 4096)
                if not data:
                    print("[bridge] end of serial stream")
                    break
                conn.sendall(data)
            except OSError as e:
                print(f"[bridge] serial error: {e}")
                break
    except Exception as e:
        print(f"[bridge] error: {e}")
    finally:
        os.close(fd)
        sock.close()


if __name__ == "__main__":
    main()
