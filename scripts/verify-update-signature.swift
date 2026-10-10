#!/usr/bin/swift
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Checks an update's EdDSA signature against the app's SUPublicEDKey, the key installed copies use.
// Usage: swift scripts/verify-update-signature.swift <base64 public key> <base64 signature> <archive>

import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4, let key = Data(base64Encoded: args[1]), let signature = Data(base64Encoded: args[2]),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
      let archive = FileManager.default.contents(atPath: args[3]) else {
    FileHandle.standardError.write(Data("usage: verify-update-signature <public key> <signature> <archive>\n".utf8))
    exit(2)
}
exit(publicKey.isValidSignature(signature, for: archive) ? 0 : 1)
