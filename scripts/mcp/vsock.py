"""VMCI vSockets on Windows: address family lookup and listen/accept/connect through ws2_32.

Python's socket module cannot build sockaddr_vm, so bind/connect/accept go through ctypes and the
resulting handle is wrapped in a normal socket object for send/recv.
"""
import ctypes
import re
import socket
import subprocess

CID_ANY = 0xFFFFFFFF
_INVALID_SOCKET = ctypes.c_size_t(-1).value


class SockaddrVm(ctypes.Structure):
    _fields_ = [("family", ctypes.c_ushort), ("reserved1", ctypes.c_ushort), ("port", ctypes.c_uint),
                ("cid", ctypes.c_uint), ("zero", ctypes.c_ubyte * 4)]


def parse_af(catalog_text: str) -> int:
    for block in re.split(r"\r?\n\s*\r?\n", catalog_text):
        if "vSockets STREAM" in block:
            match = re.search(r"Address Family:\s+(\d+)", block)
            if match:
                return int(match.group(1))
    raise OSError("vSockets STREAM provider not found in the Winsock catalog (is VMware vSockets installed?)")


def af_value() -> int:
    out = subprocess.run(["netsh", "winsock", "show", "catalog"], capture_output=True, text=True, check=True).stdout
    return parse_af(out)


def _ws2():
    ws2 = ctypes.WinDLL("ws2_32", use_last_error=True)
    ws2.socket.restype = ctypes.c_size_t
    ws2.socket.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int]
    ws2.accept.restype = ctypes.c_size_t
    ws2.accept.argtypes = [ctypes.c_size_t, ctypes.c_void_p, ctypes.c_void_p]
    for name in ("bind", "connect"):
        getattr(ws2, name).argtypes = [ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int]
    ws2.listen.argtypes = [ctypes.c_size_t, ctypes.c_int]
    ws2.closesocket.argtypes = [ctypes.c_size_t]
    return ws2


def _new_socket(ws2, af):
    handle = ws2.socket(af, socket.SOCK_STREAM, 0)
    if handle == _INVALID_SOCKET:
        raise OSError(ctypes.get_last_error(), "vsock socket()")
    return handle


def _check(ws2, rc, handle, what):
    if rc != 0:
        err = ctypes.get_last_error()
        ws2.closesocket(handle)
        raise OSError(err, what)


class Listener:
    def __init__(self, port: int):
        self._ws2 = _ws2()
        self.af = af_value()
        self._handle = _new_socket(self._ws2, self.af)
        addr = SockaddrVm(self.af, 0, port, CID_ANY)
        _check(self._ws2, self._ws2.bind(self._handle, ctypes.byref(addr), ctypes.sizeof(addr)), self._handle,
               f"vsock bind port {port}")
        _check(self._ws2, self._ws2.listen(self._handle, 4), self._handle, "vsock listen")

    def accept(self) -> socket.socket:
        conn = self._ws2.accept(self._handle, None, None)
        if conn == _INVALID_SOCKET:
            raise OSError(ctypes.get_last_error(), "vsock accept")
        return socket.socket(self.af, socket.SOCK_STREAM, 0, fileno=conn)


def connect(cid: int, port: int) -> socket.socket:
    ws2 = _ws2()
    af = af_value()
    handle = _new_socket(ws2, af)
    addr = SockaddrVm(af, 0, port, cid)
    _check(ws2, ws2.connect(handle, ctypes.byref(addr), ctypes.sizeof(addr)), handle, f"vsock connect cid {cid} port {port}")
    return socket.socket(af, socket.SOCK_STREAM, 0, fileno=handle)
