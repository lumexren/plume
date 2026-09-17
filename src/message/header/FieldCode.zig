// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of plume.
//
// Copyright (c) 2026 erffy
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

/// The type code for a D-Bus message header field.
pub const FieldCode = enum(u8) {
    Invalid = 0x0,
    Path = 0x1,
    Interface = 0x2,
    Member = 0x3,
    ErrorName = 0x4,
    ReplySerial = 0x5,
    Destination = 0x6,
    Sender = 0x7,
    Signature = 0x8,
    UnixFds = 0x9,
};
