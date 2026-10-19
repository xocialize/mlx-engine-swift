//
//  AdapterContractTests.swift
//  MLXToolKitTests
//
//  Contract 1.53.0 (AB-A-0189) — the typed-adapter types on their own: wire shapes, the
//  catalog and declaration validation, slot ordering, and the plan the engine's pre-flight runs.
//

import Foundation
import Testing
@testable import MLXToolKit

let pinnedRevision = String(repeating: "a", count: 40)
let fileDigest = String(repeating: "b", count: 64)

func plainAdapter(id: String = "anime", base: String = "klein-4b",
                  capabilities: [Capability] = [.textToImage],
                  format: AdapterFormat = .diffusersPEFT,
                  range: AdapterStrengthRange? = nil, defaultStrength: Double = 1) -> AdapterDescriptor {
    AdapterDescriptor(id: id, format: format, baseModels: [base], capabilities: capabilities,
                      source: AdapterSource(repo: "org/\(id)", revision: pinnedRevision,
                                            file: "\(id).safetensors", sha256: fileDigest, bytes: 10),
                      license: .apache2, defaultStrength: defaultStrength, strengthRange: range)
}

func poseAdapter() -> AdapterDescriptor {
    AdapterDescriptor(
        id: "refcontrol-pose", kind: .referenceConditioned, format: .bflFused,
        baseModels: ["klein-4b"], capabilities: [.imageEdit],
        source: AdapterSource(repo: "org/pose", revision: pinnedRevision, file: "pose.safetensors",
                              sha256: fileDigest),
        license: .apache2,
        conditioning: [AdapterConditioningSlot(role: "pose", media: .image),
                       AdapterConditioningSlot(role: "subject", media: .image, maxCount: 2),
                       AdapterConditioningSlot(role: "style", media: .image, required: false)],
        footprint: AdapterFootprint(residentBytes: 100, activationMultiplier: 2))
}

private func image(_ byte: UInt8) -> ConditioningMedia {
    .image(Image(format: .png, data: Data([byte])))
}

private func refusal(_ body: () throws -> Void) -> String? {
    do { try body() } catch PackageError.unsupportedRequestFeature(let detail) { return detail } catch {
        return "unexpected \(error)"
    }
    return nil
}

@Suite("Typed adapters — contract 1.53.0")
struct AdapterContractTests {

    @Test func contractIsAt1_53() {
        #expect(ContractVersion.current >= SemanticVersion(major: 1, minor: 53, patch: 0))
    }

    @Test func requestsCarryAdaptersAndTheEngineStampsTheResolvedForm() {
        let ref = AdapterRef(id: "anime", strength: 0.8)
        let t2i = T2IRequest(prompt: "p", adapters: [ref])
        #expect(t2i.adapters == [ref])
        #expect(t2i.resolvedAdapters.isEmpty)

        let resolved = ResolvedAdapter(id: "anime", kind: .plain, format: .diffusersPEFT,
                                       fileURL: URL(fileURLWithPath: "/tmp/a.safetensors"),
                                       source: plainAdapter().source, strength: 0.8,
                                       footprint: AdapterFootprint(residentBytes: 10))
        #expect(t2i.resolving([resolved]).resolvedAdapters == [resolved])
        #expect(t2i.resolving([resolved]).prompt == "p")

        // Every adapter-carrying request conforms, and a request without adapters defaults to [].
        let carriers: [any AdapterCarrying] = [
            T2IRequest(prompt: "p"),
            IEditRequest(images: [], prompt: "p"),
            T2VRequest(prompt: "p"),
            VEditRequest(video: Video(format: .mp4, data: Data()), prompt: "p"),
        ]
        #expect(carriers.allSatisfy { $0.adapters.isEmpty })
        #expect(Set(carriers.map { type(of: $0).capability }) == AdapterSupport.carryingCapabilities)
    }

    @Test func adapterRefDecodesWithoutConditioning() throws {
        let ref = try JSONDecoder().decode(AdapterRef.self, from: Data(#"{"id":"anime"}"#.utf8))
        #expect(ref == AdapterRef(id: "anime"))

        let ic = AdapterRef(id: "pose", strength: 1.2,
                            conditioning: [ConditioningInput(role: "pose", media: image(1), strength: 0.5)])
        let roundTrip = try JSONDecoder().decode(AdapterRef.self, from: JSONEncoder().encode(ic))
        #expect(roundTrip == ic)
    }

    @Test func descriptorRoundTripsAndDecodesMinimalRegistryEntries() throws {
        let pose = poseAdapter()
        #expect(try JSONDecoder().decode(AdapterDescriptor.self, from: JSONEncoder().encode(pose)) == pose)

        let minimal = """
        {"id":"anime","format":"diffusers-peft","baseModels":["klein-4b"],
         "capabilities":["textToImage"],"license":"Apache-2.0",
         "source":{"repo":"org/anime","revision":"\(pinnedRevision)",
                   "file":"anime.safetensors","sha256":"\(fileDigest.uppercased())"}}
        """
        let decoded = try JSONDecoder().decode(AdapterDescriptor.self, from: Data(minimal.utf8))
        #expect(decoded.kind == .plain)
        #expect(decoded.defaultStrength == 1)
        #expect(decoded.conditioning.isEmpty)
        #expect(decoded.validationProblems.isEmpty)
        // The digest is normalized to lowercase, which is what the store keys on.
        #expect(decoded.source.sha256 == fileDigest)
    }

    @Test func descriptorValidationNamesEveryProblem() {
        #expect(plainAdapter().validationProblems.isEmpty)
        #expect(poseAdapter().validationProblems.isEmpty)

        let unpinned = AdapterDescriptor(
            id: "x", format: .kohya, baseModels: ["b"], capabilities: [.llm],
            source: AdapterSource(repo: "nope", revision: "main", file: "../x.safetensors", sha256: "abc"),
            license: .apache2, defaultStrength: 3,
            strengthRange: AdapterStrengthRange(min: 0, max: 2))
        let problems = unpinned.validationProblems.joined(separator: " | ")
        #expect(problems.contains("not org/name"))
        #expect(problems.contains("not a 40-character commit hash"))
        #expect(problems.contains("not 64 hex characters"))
        #expect(problems.contains("not a relative path"))
        #expect(problems.contains("adapter-carrying capability"))
        #expect(problems.contains("outside its strengthRange"))

        // A reference-conditioned adapter must declare slots AND a footprint; a plain one no slots.
        let bareIC = AdapterDescriptor(id: "ic", kind: .referenceConditioned, format: .kohya,
                                       baseModels: ["b"], capabilities: [.textToVideo],
                                       source: plainAdapter().source, license: .apache2)
        #expect(bareIC.validationProblems.contains { $0.contains("no conditioning slots") })
        #expect(bareIC.validationProblems.contains { $0.contains("must declare its footprint") })
        let plainWithSlots = AdapterDescriptor(id: "p", format: .kohya, baseModels: ["b"],
                                               capabilities: [.textToImage], source: plainAdapter().source,
                                               license: .apache2,
                                               conditioning: [AdapterConditioningSlot(role: "r", media: .image)])
        #expect(plainWithSlots.validationProblems.contains { $0.contains("only a reference-conditioned") })
    }

    @Test func conditioningIsOrderedIntoSlotOrder() throws {
        let pose = poseAdapter()
        let ordered = try pose.orderedConditioning([
            ConditioningInput(role: "subject", media: image(2)),
            ConditioningInput(role: "pose", media: image(1)),
            ConditioningInput(role: "subject", media: image(3)),
        ])
        #expect(ordered.map(\.role) == ["pose", "subject", "subject"])
        #expect(ordered.map(\.media) == [image(1), image(2), image(3)])

        #expect(refusal { _ = try pose.orderedConditioning([ConditioningInput(role: "subject", media: image(2))]) }?
            .contains("\"pose\" is required") == true)
        #expect(refusal { _ = try pose.orderedConditioning([
            ConditioningInput(role: "pose", media: image(1)),
            ConditioningInput(role: "subject", media: image(2)),
            ConditioningInput(role: "depth", media: image(3)),
        ]) }?.contains("not one of its slots") == true)
        #expect(refusal { _ = try pose.orderedConditioning([
            ConditioningInput(role: "pose", media: .audio(Audio(data: Data()))),
            ConditioningInput(role: "subject", media: image(2)),
        ]) }?.contains("takes image, not audio") == true)
        #expect(refusal { _ = try pose.orderedConditioning([
            ConditioningInput(role: "pose", media: image(1)),
            ConditioningInput(role: "subject", media: image(2)),
            ConditioningInput(role: "subject", media: image(3)),
            ConditioningInput(role: "subject", media: image(4)),
        ]) }?.contains("at most 2") == true)
        #expect(refusal { _ = try plainAdapter().orderedConditioning([
            ConditioningInput(role: "pose", media: image(1)),
        ]) }?.contains("plain adapter takes no conditioning") == true)
    }

    @Test func declaringAdaptersAdvertisesTheParameterAndDecodesLegacyJSON() throws {
        let plain = T2IContract.descriptor(name: "t2i", summary: "s")
        #expect(plain.adapters == nil)
        #expect(!plain.parameters.contains { $0.name == "adapters" })

        let support = AdapterSupport(baseModel: "klein-4b", formats: [.bflFused, .diffusersPEFT],
                                     maxCount: 3)
        let declared = plain.declaring(adapters: support).declaring(rawImageFormats: [.rawBGRA8])
        #expect(declared.adapters == support)          // survives the other `declaring`
        #expect(declared.parameters.filter { $0.name == "adapters" }.count == 1)
        #expect(declared.adaptersMatchCapability)
        #expect(declared.declaring(adapters: support).parameters.filter { $0.name == "adapters" }.count == 1)

        // Pre-1.53 descriptor JSON has no `adapters` key.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as! [String: Any]
        json["adapters"] = nil
        let legacy = try JSONDecoder().decode(ToolDescriptor.self,
                                              from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.adapters == nil)
        #expect(try JSONDecoder().decode(ToolDescriptor.self, from: JSONEncoder().encode(declared)) == declared)

        let onLLM = LLMContract.descriptor(name: "llm", summary: "s").declaring(adapters: support)
        #expect(!onLLM.adaptersMatchCapability)
    }

    @Test func supportValidation() {
        #expect(AdapterSupport(baseModel: "b", formats: [.kohya]).validationProblems.isEmpty)
        let bad = AdapterSupport(baseModel: "", formats: [], kinds: [], maxCount: 0,
                                 strengthRange: AdapterStrengthRange(min: 2, max: 1), quants: [])
        #expect(bad.validationProblems.count == 6)
    }

    @Test func planAdmitsAndRefusesLegibly() throws {
        let catalog = [plainAdapter(), poseAdapter(),
                       plainAdapter(id: "other-base", base: "qwen-image"),
                       plainAdapter(id: "kohya", format: .kohya),
                       plainAdapter(id: "narrow", range: AdapterStrengthRange(min: 0.5, max: 0.9),
                                    defaultStrength: 0.7)]
        let lookup = { (id: String) in catalog.first { $0.id == id } }
        let support = AdapterSupport(baseModel: "klein-4b", formats: [.diffusersPEFT, .bflFused],
                                     kinds: [.plain, .referenceConditioned], maxCount: 2,
                                     strengthRange: AdapterStrengthRange(min: 0, max: 1.5),
                                     quants: [.bf16, .int8])

        let plans = try support.plan([AdapterRef(id: "anime"), AdapterRef(id: "narrow")],
                                     capability: .textToImage, quant: .bf16, lookup: lookup)
        #expect(plans.map(\.strength) == [1, 0.7])     // defaults applied

        func refused(_ refs: [AdapterRef], _ capability: Capability = .textToImage,
                     quant: Quant? = .bf16) -> String {
            refusal { _ = try support.plan(refs, capability: capability, quant: quant, lookup: lookup) } ?? "admitted"
        }
        #expect(refused([AdapterRef(id: "a"), AdapterRef(id: "b"), AdapterRef(id: "c")]).contains("at most 2"))
        #expect(refused([AdapterRef(id: "anime"), AdapterRef(id: "anime")]).contains("repeated"))
        #expect(refused([AdapterRef(id: "ghost")]).contains("not in the engine's adapter catalog"))
        #expect(refused([AdapterRef(id: "other-base")]).contains("not this surface's base model klein-4b"))
        #expect(refused([AdapterRef(id: "kohya")]).contains("kohya dialect"))
        #expect(refused([AdapterRef(id: "anime")], .imageEdit).contains("not imageEdit"))
        #expect(refused([AdapterRef(id: "anime")], quant: .int4).contains("only at bf16, int8"))
        #expect(refused([AdapterRef(id: "anime", strength: 1.6)]).contains("outside the admitted range 0.0…1.5"))
        #expect(refused([AdapterRef(id: "narrow", strength: 1.0)]).contains("outside the admitted range 0.5…0.9"))
        #expect(refused([AdapterRef(id: "anime", strength: .nan)]).contains("outside"))
        #expect(refused([AdapterRef(id: "refcontrol-pose")], .imageEdit).contains("\"pose\" is required"))
        // An unknown quant is not refused: unknowable is not the same as outside.
        #expect(refused([AdapterRef(id: "anime")], quant: nil) == "admitted")

        let plainOnly = AdapterSupport(baseModel: "klein-4b", formats: [.bflFused])
        #expect(refusal { _ = try plainOnly.plan([AdapterRef(id: "refcontrol-pose")], capability: .imageEdit,
                                                 quant: nil, lookup: lookup) }?
            .contains("is a ic adapter") == true)
    }
}

// MARK: - Conditioning groups (contract 1.55.0)

/// LTX Ingredients as adapter registry format 3 writes it (xocialize/ltx-lora-registry v0.2.0),
/// registry-only keys included and long notes shortened: a superset of `AdapterDescriptor`.
private let ingredientsEntry = """
{"id":"ingredients","title":"Ingredients","kind":"ic","format":"diffusers-peft",
 "baseModels":["ltx-2.3","ltx-2.5"],"capabilities":["textToVideo"],
 "clearance":{"ltx-2.3":{"level":"perceptual","variant":"distilled"}},
 "source":{"host":"huggingface","repo":"Lightricks/LTX-2.3-22b-IC-LoRA-Ingredients",
           "revision":"dcc403d92aa0f5a983c5dbc7282503ca52f73a08",
           "file":"ltx-2.3-22b-ic-lora-ingredients-0.9.safetensors",
           "sha256":"515e4e139001ac6282357a5b35372e42e98b3affd5fcc886a52242abeed19559",
           "bytes":1308778338,"gated":true,"hashFrom":"local"},
 "license":"LicenseRef-LTX-2-Community",
 "licenseTerms":{"commercialUse":"conditional","gated":true},
 "defaultStrength":1.4,"status":"verified","promptConvention":"ingredients-dual-part",
 "conditioning":[
   {"role":"reference_sheet","media":"image","required":false,"group":"sheet","ingest":"loopedStillVideo","note":"one finished sheet"},
   {"role":"subject_images","media":"image","maxCount":6,"required":false,"group":"sheet","ingest":"sheetBuilder"},
   {"role":"location_image","media":"image","required":false,"group":"sheet","ingest":"sheetBuilder"}],
 "conditioningGroups":{"sheet":{"rule":"exactlyOne","required":true,"alternatives":[
   {"requires":["reference_sheet"]},
   {"requires":["subject_images"],"allows":["location_image"]}]}},
 "footprint":{"residentBytes":1308778338,"activationMultiplier":1.64},
 "runtime":{"referenceDownscale":1,"stage2":"skip"},
 "verification":{"gate":"1344/1344"}}
"""

@Suite("Adapter conditioning groups — contract 1.55.0")
struct AdapterConditioningGroupTests {

    private func input(_ role: String) -> ConditioningInput {
        ConditioningInput(role: role, media: .image(Image(format: .png, data: Data([1]))))
    }

    private func refusal(_ body: () throws -> Void) -> String? {
        do { try body() } catch PackageError.unsupportedRequestFeature(let detail) { return detail } catch {
            return "unexpected \(error)"
        }
        return nil
    }

    @Test func aFormat3RegistryEntryDecodesWithItsGroup() throws {
        let ingredients = try JSONDecoder().decode(AdapterDescriptor.self, from: Data(ingredientsEntry.utf8))
        #expect(ingredients.validationProblems.isEmpty)
        #expect(ingredients.kind == .referenceConditioned)
        #expect(ingredients.footprint == AdapterFootprint(residentBytes: 1_308_778_338, activationMultiplier: 1.64))
        #expect(ingredients.conditioningGroups["sheet"]?.roles == ["reference_sheet", "subject_images", "location_image"])
        let roundTrip = try JSONDecoder().decode(AdapterDescriptor.self, from: JSONEncoder().encode(ingredients))
        #expect(roundTrip == ingredients)
        // A descriptor without groups keeps its pre-1.55 wire shape.
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plainAdapter())) as? [String: Any]
        #expect(plain?["conditioningGroups"] == nil)
    }

    @Test func exactlyOneAlternativeMustBeBound() throws {
        let ingredients = try JSONDecoder().decode(AdapterDescriptor.self, from: Data(ingredientsEntry.utf8))
        // Either alternative, the second with or without its optional role.
        #expect(try ingredients.orderedConditioning([input("reference_sheet")]).map(\.role) == ["reference_sheet"])
        #expect(try ingredients.orderedConditioning([input("location_image"), input("subject_images"),
                                                     input("subject_images")]).map(\.role)
            == ["subject_images", "subject_images", "location_image"])

        // No sheet at all — what 1.53.0 admitted.
        #expect(refusal { _ = try ingredients.orderedConditioning([]) }?
            .contains("bind exactly one of: reference_sheet | subject_images (+ optional location_image)") == true)
        // Mixing the alternatives.
        #expect(refusal { _ = try ingredients.orderedConditioning([input("reference_sheet"), input("subject_images")]) }?
            .contains("match none of") == true)
        // The optional role alone.
        #expect(refusal { _ = try ingredients.orderedConditioning([input("location_image")]) }?
            .contains("(location_image) match none of") == true)
    }

    @Test func anOptionalGroupMayBeLeftUnbound() throws {
        let slots = [AdapterConditioningSlot(role: "pose", media: .image),
                     AdapterConditioningSlot(role: "depth", media: .image, required: false),
                     AdapterConditioningSlot(role: "edges", media: .image, required: false)]
        let adapter = AdapterDescriptor(
            id: "control", kind: .referenceConditioned, format: .diffusersPEFT, baseModels: ["b"],
            capabilities: [.textToImage], source: plainAdapter().source, license: .apache2,
            conditioning: slots,
            conditioningGroups: ["hint": AdapterConditioningGroup(required: false, alternatives: [
                .init(requires: ["depth"]), .init(requires: ["edges"])])],
            footprint: AdapterFootprint(residentBytes: 1, activationMultiplier: 1.2))
        #expect(adapter.validationProblems.isEmpty)
        #expect(try adapter.orderedConditioning([input("pose")]).count == 1)
        #expect(try adapter.orderedConditioning([input("pose"), input("edges")]).count == 2)
        #expect(refusal { _ = try adapter.orderedConditioning([input("pose"), input("depth"), input("edges")]) }?
            .contains("match none of: depth | edges") == true)
    }

    @Test func malformedGroupsFailValidationSoTheyCannotRegister() {
        let slots = [AdapterConditioningSlot(role: "a", media: .image),
                     AdapterConditioningSlot(role: "b", media: .image, required: false)]
        let adapter = AdapterDescriptor(
            id: "bad", kind: .referenceConditioned, format: .kohya, baseModels: ["b"],
            capabilities: [.textToImage], source: plainAdapter().source, license: .apache2,
            conditioning: slots,
            conditioningGroups: [
                "one": AdapterConditioningGroup(rule: "atLeastOne", alternatives: [.init(requires: ["a"]),
                                                                                  .init(requires: ["ghost"])]),
                "two": AdapterConditioningGroup(alternatives: [.init(requires: ["b"]), .init(requires: [])]),
                "three": AdapterConditioningGroup(alternatives: [.init(requires: ["b"])]),
            ],
            footprint: AdapterFootprint(residentBytes: 1))
        let problems = adapter.validationProblems.joined(separator: " | ")
        #expect(problems.contains("rule \"atLeastOne\""))
        #expect(problems.contains("\"ghost\", which is not a slot"))
        #expect(problems.contains("slot \"a\" is in group \"one\" and must be required: false"))
        #expect(problems.contains("group \"two\" needs alternatives, each requiring a role"))
        #expect(problems.contains("slot \"b\" is in two groups"))
    }
}
