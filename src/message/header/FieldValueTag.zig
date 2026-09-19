// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of plume.
//
// Copyright (c) 2026 erenvly
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://gnu.org/licenses>.

pub const FieldValueTag = enum {
    /// The object to send a call to, or the object a signal is emitted from.
    /// The special path `/org/freedesktop/DBus/Local` is reserved; implementations
    /// should not send messages with this path, and the reference implementation
    /// of the bus daemon will disconnect any application that attempts to do so.
    /// This header field is controlled by the message sender.
    ///
    /// **Required In**: `MethodCall`, `Signal`
    Path,
    ///  The interface to invoke a method call on, or that a signal is emitted from.
    ///  Optional for method calls, required for signals.
    ///  The special interface `org.freedesktop.DBus.Local` is reserved;
    ///  implementations should not send messages with this interface,
    ///  and the reference implementation of the bus daemon will disconnect any
    ///  application that attempts to do so. This header field is controlled by
    ///  the message sender.
    ///
    ///  **Required In**: Signal
    Interface,
    ///  The member, either the method name or signal name. This header field
    ///  is controlled by the message sender.
    ///
    /// **Required In**: `MethodCall`, `Signal`
    Member,
    /// The name of the error that occurred, for errors
    ///
    /// **Required In**: `Error`
    ErrorName,
    ///  The serial number of the message this message is a reply to.
    ///  (The serial number is the second UINT32 in the header.)
    ///  This header field is controlled by the message sender.
    ///
    ///  **Required In**: `Error`, `MethodReturn`
    ReplySerial,
    ///  The name of the connection this message is intended for. This field is
    ///  usually only meaningful in combination with the message bus¹ but other
    ///  servers may define their own meanings for it. This header field is
    ///  controlled by the message sender.
    ///
    ///  ¹see [the section called "Message Bus Specification"](https://dbus.freedesktop.org/doc/dbus-specification.html#message-bus)
    ///
    /// **~optional**
    Destination,
    /// Unique name of the sending connection. This field is usually only
    /// meaningful in combination with the message bus, but other servers may
    /// define their own meanings for it. On a message bus, this header field
    /// is controlled by the message bus, so it is as reliable and trustworthy
    /// as the message bus itself. Otherwise, this header field is controlled
    /// by the message sender, unless there is out-of-band information that
    /// indicates otherwise.
    ///
    /// **~optional**
    Sender,
    /// The signature of the message body.
    /// If omitted, it is assumed to be the empty signature "" (i.e. the body must be 0-length).
    /// This header field is controlled by the message sender.
    ///
    /// **~optional**
    Signature,
    /// The number of Unix file descriptors that accompany the message.
    /// If omitted, it is assumed that no Unix file descriptors accompany the message.
    /// The actual file descriptors need to be transferred via platform specific
    /// mechanism out-of-band. They must be sent at the same time as part of the
    /// message itself. They may not be sent before the first byte of the message
    /// itself is transferred or after the last byte of the message itself.
    /// This header field is controlled by the message sender.
    ///
    /// **~optional**
    UnixFds,
};
