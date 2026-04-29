//! Public surface of the wire-format schema package.

const std = @import("std");

pub const build_options = @import("build_options");

pub const version = @import("version.zig");
pub const ProtocolVersion = version.ProtocolVersion;

pub const serde_util = @import("serde_util.zig");
pub const RawValue = serde_util.RawValue;

pub const rpc = @import("rpc.zig");
pub const RequestId = rpc.RequestId;
pub const Request = rpc.Request;
pub const Response = rpc.Response;
pub const ResponseError = rpc.ResponseError;
pub const Notification = rpc.Notification;
pub const JsonRpcMessage = rpc.JsonRpcMessage;
pub const JSONRPC_VERSION = rpc.JSONRPC_VERSION;

pub const @"error" = @import("error.zig");
pub const Error = @"error".Error;
pub const ErrorCode = @"error".Code;

pub const content = @import("content.zig");
pub const ContentBlock = content.ContentBlock;
pub const TextContent = content.TextContent;
pub const ImageContent = content.ImageContent;
pub const AudioContent = content.AudioContent;
pub const EmbeddedResource = content.EmbeddedResource;
pub const ResourceLink = content.ResourceLink;
pub const ResourceContents = content.ResourceContents;

pub const plan = @import("plan.zig");
pub const Plan = plan.Plan;
pub const PlanEntry = plan.PlanEntry;
pub const PlanEntryStatus = plan.PlanEntryStatus;
pub const Priority = plan.Priority;

pub const ext = @import("ext.zig");
pub const ExtRequest = ext.ExtRequest;
pub const ExtResponse = ext.ExtResponse;
pub const ExtNotification = ext.ExtNotification;

pub const tool_call = @import("tool_call.zig");
pub const ToolCall = tool_call.ToolCall;
pub const ToolCallId = tool_call.ToolCallId;
pub const ToolCallStatus = tool_call.ToolCallStatus;
pub const ToolKind = tool_call.ToolKind;
pub const ToolCallContent = tool_call.ToolCallContent;
pub const ToolCallLocation = tool_call.ToolCallLocation;
pub const ToolCallUpdate = tool_call.ToolCallUpdate;

pub const protocol_level = @import("protocol_level.zig");
pub const elicitation = @import("elicitation.zig");
pub const nes = @import("nes.zig");

test {
    std.testing.refAllDecls(@This());
}
