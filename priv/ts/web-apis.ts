import { AbortSignal, AbortController } from './abort'
import { Blob, File } from './blob'
import { BroadcastChannel } from './broadcast-channel'
import { DOMException } from './dom-exception'
import { Event, MessageEvent, CloseEvent, ErrorEvent } from './event'
import { EventSource } from './event-source'
import { EventTarget } from './event-target'
import { Request, Response, fetch } from './fetch'
import { FormData } from './form-data'
import { Headers } from './headers'
import {
  ReadableStream,
  ReadableStreamDefaultReader,
  WritableStream,
  WritableStreamDefaultWriter,
  TransformStream
} from './streams'
import { TextDecoderStream, TextEncoderStream } from './text-streams'
import { WebSocket } from './websocket'
import { MessageChannel, MessagePort } from './message-channel'
import { Worker } from './worker'
import './console-ext'
import './locks'
import './performance'
import './storage'

Object.assign(globalThis, {
  DOMException,
  Event,
  MessageEvent,
  CloseEvent,
  ErrorEvent,
  EventTarget,
  AbortSignal,
  AbortController,
  ReadableStream,
  ReadableStreamDefaultReader,
  WritableStream,
  WritableStreamDefaultWriter,
  TransformStream,
  TextEncoderStream,
  TextDecoderStream,
  Blob,
  File,
  FormData,
  Headers,
  Request,
  Response,
  fetch,
  BroadcastChannel,
  MessageChannel,
  MessagePort,
  WebSocket,
  Worker,
  EventSource
})
