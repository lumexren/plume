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

pub const Flag = enum(u8) {
    __EMPTY = 0x0,
    /// This message does not expect method return replies or error replies,
    /// even if it is of a type that can have a reply; the reply should be omitted.
    /// Note that `METHOD_CALL` is the only message type currently defined in
    /// this specification that can expect a reply, so the presence or absence
    /// of this flag in the other three message types that are currently documented
    /// is meaningless: replies to those message types should not be sent, whether
    /// this flag is present or not.
    NoReplyExpected = 0x1,
    /// The bus must not launch an owner for the destination name in response
    /// to this message.
    NoAutoStart = 0x2,
    /// This flag may be set on a method call message to inform the receiving
    /// side that the caller is prepared to wait for interactive authorization,
    /// which might take a considerable time to complete. For instance, if this
    /// flag is set, it would be appropriate to query the user for passwords or
    /// confirmation via Polkit or a similar framework.
    ///
    /// This flag is only useful when unprivileged code calls a more privileged
    /// method call, and an authorization framework is deployed that allows possibly
    /// interactive authorization. If no such framework is deployed it has no
    /// effect. This flag should not be set by default by client implementations.
    /// If it is set, the caller should also set a suitably long timeout on
    /// the method call to make sure the user interaction may complete.
    /// This flag is only valid for method call messages, and shall be
    /// ignored otherwise.
    ///
    /// Interaction that takes place as a part of the effect of the method being
    /// called is outside the scope of this flag, even if it could also be
    /// characterized as authentication or authorization. For instance, in a
    /// method call that directs a network management service to attempt to connect
    /// to a virtual private network, this flag should control how the network
    /// management service makes the decision
    /// "is this user allowed to change system network configuration?",
    /// but it should not affect how or whether the network management service
    /// interacts with the user to obtain the credentials that are required
    /// for access to the VPN.
    ///
    /// If a this flag is not set on a method call, and a service determines
    /// that the requested operation is not allowed without interactive authorization,
    /// but could be allowed after successful interactive authorization, it may
    /// return the `org.freedesktop.DBus.Error.InteractiveAuthorizationRequired` error.
    ///
    /// The absence of this flag does not guarantee that interactive authorization
    /// will not be applied, since existing services that pre-date this flag
    /// might already use interactive authorization. However, existing D-Bus APIs
    /// that will use interactive authorization should document that the call may
    /// take longer than usual, and new D-Bus APIs should avoid interactive authorization
    /// in the absence of this flag.
    AllowInteractiveAuthorization = 0x4,
};
