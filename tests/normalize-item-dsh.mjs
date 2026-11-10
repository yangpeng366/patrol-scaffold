#!/usr/bin/env node
/**
 * tests/normalize-item-dsh.mjs — 对拍用的「dsh-patrol 侧真实解析」入口（只读 / 离线 / 零依赖）。
 *
 * 为什么要有它：tests/verify-item-parity-e2e.ps1 要比两仓对**同一份行数据**的解析结果。
 * 右侧必须是 dsh-patrol 自己的代码跑出来的，不能在本仓手抄一份 normalizeItem 冒充对拍
 * （手抄的那份只会证明抄得像，不证明两仓一致）。所以这里 import 兄弟仓真实的
 * `src/source/bitable.ts`（内含 COLUMNS 列映射 + 走 `normalizeItem`），只把
 * lark-cli 子进程换成注入的 `exec`——返回 fixture 的 `+record-list` 信封，
 * 不联网、不读凭据、不碰真表。列映射、单元格拆包、normalizeItem 全部走 dsh 原码。
 *
 * 为什么还用 `--experimental-strip-types`：dsh-patrol 的 import 带 `.ts` 后缀，
 * 本机没有 tsx（node_modules 里也没有），Node 22 的类型擦除能直接跑 TS 源码，
 * 不需要构建、不需要装依赖。probe 由 PowerShell 侧做（拿不到就 SKIP，不 FAIL）。
 *
 * 输入（--rows）：{ "fields": ["项目名", ...], "rows": [{ "recordId": "rec-1", "cells": { "项目名": "x" } }] }
 * 输出（stdout，单个 JSON）：{ dsh: {...}, items: [ { <字段>: "<类型标签>:<值>" } ] }
 *   —— 值带类型标签前缀（s:=字符串 / n:=数字 / b:=布尔 / z=null）。
 *   为什么不直接吐 JSON 原生类型：PowerShell 的 ConvertFrom-Json 会把 ISO 时间串
 *   自动转成 [DateTime]，lastRun 这类字段一到 PS 侧就被改成区域格式，对拍会假红（或假绿）。
 *   前缀成 "s:2026-11-10T08:00:00.000Z" 之后不再像日期，读回来仍是原字符串。
 *
 * 用法：
 *   node --experimental-strip-types --no-warnings tests/normalize-item-dsh.mjs \
 *        --repo D:\gitAll\dsh-patrol --rows %TEMP%\rows.json
 */
import { readFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

function parseArgs(argv) {
  const out = {}
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i]
    if (!key || !key.startsWith('--')) throw new Error(`bad argument: ${key}`)
    out[key.slice(2)] = argv[i + 1]
  }
  if (!out.repo) throw new Error('missing --repo <dsh-patrol 克隆根目录>')
  if (!out.rows) throw new Error('missing --rows <fixture rows json>')
  return out
}

const args = parseArgs(process.argv.slice(2))
const repo = resolve(args.repo)
const bitablePath = join(repo, 'src', 'source', 'bitable.ts')
const providerPath = join(repo, 'src', 'source', 'provider.ts')

// 动态 import：文件缺失时给出可读错误，而不是一句 ENOENT 栈。
const provider = await import(pathToFileURL(providerPath).href)
if (typeof provider.normalizeItem !== 'function') {
  throw new Error(`dsh-patrol provider module has no normalizeItem: ${providerPath}`)
}
const { BitableSource, resolveLarkCli } = await import(pathToFileURL(bitablePath).href)
if (typeof BitableSource !== 'function') {
  throw new Error(`dsh-patrol bitable module has no BitableSource: ${bitablePath}`)
}

const doc = JSON.parse(await readFile(args.rows, 'utf8'))
const fields = doc.fields
const rows = doc.rows

// 构造 lark-cli base +record-list 的真实信封形状：矩阵 + 平行 fields + record_id_list。
// 缺列的行按 null 填格（Bitable 里空单元格就是这个形状）；缺列即"这一行没这个字段"。
const envelope = {
  ok: true,
  data: {
    data: rows.map((r) => fields.map((f) => (Object.prototype.hasOwnProperty.call(r.cells, f) ? r.cells[f] : null))),
    fields,
    record_id_list: rows.map((r) => r.recordId),
    has_more: false,
  },
}

const commands = []
const source = new BitableSource({
  baseToken: 'fixture-base-token',
  tableId: 'fixture-table-id',
  exec: async (file, cmdArgs) => {
    commands.push([file, ...cmdArgs].join(' '))
    return { stdout: JSON.stringify(envelope) }
  },
})

const items = await source.listItems()

function tagged(value) {
  if (value === null || value === undefined) return 'z'
  if (typeof value === 'boolean') return value ? 'b:true' : 'b:false'
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new Error(`non-finite number in item: ${value}`)
    return `n:${value}`
  }
  return `s:${String(value)}`
}

const taggedItems = items.map((item) => {
  const row = {}
  for (const key of Object.keys(item).sort()) row[key] = tagged(item[key])
  return row
})

process.stdout.write(JSON.stringify({
  dsh: {
    repo,
    bitable: bitablePath,
    provider: providerPath,
    node: process.version,
    larkCli: resolveLarkCli('fixture-lark-cli'),
    commands,
  },
  items: taggedItems,
}, null, 2))
