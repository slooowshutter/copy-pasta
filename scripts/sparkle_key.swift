// Sparkle EdDSA (Ed25519) checks for scripts/release.sh, so a release can't ship an update the
// app would reject:
//   sparkle_key public < private-key          the public key (SUPublicEDKey) for a private key
//   sparkle_key verify <public-key> <signature> <file>   exit 0 if the signature is valid
// Keys and signatures are base64, as Sparkle writes them. A private key is either the 32-byte
// seed `generate_keys -x` exports, or the older 96-byte form (private key, then public key).
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sparkle_key: \(message)\n".utf8))
    exit(2)
}

func base64(_ string: String) -> Data? {
    Data(base64Encoded: string.trimmingCharacters(in: .whitespacesAndNewlines))
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "public":
    let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    guard let key = base64(input) else { fail("the private key isn't base64") }
    switch key.count {
    case 32:
        guard let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: key) else { fail("bad private key") }
        print(privateKey.publicKey.rawRepresentation.base64EncodedString())
    case 96:
        print(key.suffix(32).base64EncodedString())
    default:
        fail("a private key is 32 or 96 bytes, this one is \(key.count)")
    }
case "verify" where args.count == 4:
    guard let rawKey = base64(args[1]), let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
    else { fail("bad public key") }
    guard let signature = base64(args[2]) else { fail("bad signature") }
    guard let file = FileManager.default.contents(atPath: args[3]) else { fail("can't read \(args[3])") }
    exit(publicKey.isValidSignature(signature, for: file) ? 0 : 1)
default:
    fail("usage: sparkle_key public < key | sparkle_key verify <public-key> <signature> <file>")
}
