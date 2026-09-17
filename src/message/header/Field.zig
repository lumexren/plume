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

/// A D-Bus message header field consisting of a code and a value.
const Field = @This();

pub const Code = @import("FieldCode.zig").FieldCode;
pub const Value = @import("FieldValue.zig").FieldValue;
pub const ValueTag = @import("FieldValueTag.zig").FieldValueTag;

code: Code,
value: Value,
