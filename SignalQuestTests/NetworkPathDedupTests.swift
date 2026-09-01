import XCTest
@testable import SignalQuest

/// `NetworkPathMonitor` n'assigne plus `status` et `isOnline` qu'en cas de
/// changement réel. Il est injecté en `@EnvironmentObject` à la racine, donc
/// chaque émission réinvalide tout l'arbre de vues qui l'observe — et
/// `refreshStatus()` est déclenché par `CTServiceRadioAccessTechnologyDidChange`,
/// très fréquente en mobilité, c'est-à-dire pendant un drive test.
///
/// Le risque que cette optimisation introduit est précis : si un champ est
/// ajouté à `NetworkPathStatus` sans être pris en compte par `==`, la
/// comparaison deviendrait un filtre qui AVALE des changements réels — l'UI
/// afficherait un état périmé. C'est ce que verrouillent ces tests.
final class NetworkPathDedupTests: XCTestCase {

    private static let reference = NetworkPathStatus(
        connection: .cellular,
        cellularTechnology: .fourG,
        operatorName: "Orange",
        operatorMcc: 208,
        operatorMnc: 1,
        isExpensive: true,
        isConstrained: false
    )

    func testIdenticalStatusesCompareEqual() {
        XCTAssertEqual(Self.reference, Self.reference)
        let copy = NetworkPathStatus(
            connection: .cellular, cellularTechnology: .fourG, operatorName: "Orange",
            operatorMcc: 208, operatorMnc: 1, isExpensive: true, isConstrained: false
        )
        XCTAssertEqual(Self.reference, copy, "Deux statuts identiques ne doivent pas réinvalider les vues")
    }

    /// Chaque champ, pris isolément, doit rompre l'égalité.
    func testEveryFieldParticipatesInEquality() {
        let variants: [(String, NetworkPathStatus)] = [
            ("connection", NetworkPathStatus(
                connection: .wifi, cellularTechnology: .fourG, operatorName: "Orange",
                operatorMcc: 208, operatorMnc: 1, isExpensive: true, isConstrained: false)),
            ("cellularTechnology", NetworkPathStatus(
                connection: .cellular, cellularTechnology: .fiveGSA, operatorName: "Orange",
                operatorMcc: 208, operatorMnc: 1, isExpensive: true, isConstrained: false)),
            ("operatorName", NetworkPathStatus(
                connection: .cellular, cellularTechnology: .fourG, operatorName: "SFR",
                operatorMcc: 208, operatorMnc: 1, isExpensive: true, isConstrained: false)),
            ("operatorMcc", NetworkPathStatus(
                connection: .cellular, cellularTechnology: .fourG, operatorName: "Orange",
                operatorMcc: 262, operatorMnc: 1, isExpensive: true, isConstrained: false)),
            ("operatorMnc", NetworkPathStatus(
                connection: .cellular, cellularTechnology: .fourG, operatorName: "Orange",
                operatorMcc: 208, operatorMnc: 10, isExpensive: true, isConstrained: false)),
            ("simPlmn", NetworkPathStatus(
                connection: .cellular, cellularTechnology: .fourG, operatorName: "Orange",
                operatorMcc: 208, operatorMnc: 1, simPlmn: "20801",
                isExpensive: true, isConstrained: false)),
            ("isExpensive", NetworkPathStatus(
                connection: .cellular, cellularTechnology: .fourG, operatorName: "Orange",
                operatorMcc: 208, operatorMnc: 1, isExpensive: false, isConstrained: false)),
            ("isConstrained", NetworkPathStatus(
                connection: .cellular, cellularTechnology: .fourG, operatorName: "Orange",
                operatorMcc: 208, operatorMnc: 1, isExpensive: true, isConstrained: true))
        ]
        for (field, variant) in variants {
            XCTAssertNotEqual(
                Self.reference, variant,
                "Un changement de \(field) doit être publié, pas filtré par la déduplication"
            )
        }
    }

    /// Passer de 4G à 5G NSA est le cas typique d'un drive test : il DOIT être
    /// publié, alors qu'une notification radio répétée sur la même techno ne
    /// doit rien produire.
    func testTechnologyTransitionIsPublishedButRepetitionIsNot() {
        let fourG = Self.reference
        let fiveG = NetworkPathStatus(
            connection: .cellular, cellularTechnology: .fiveGNSA, operatorName: "Orange",
            operatorMcc: 208, operatorMnc: 1, isExpensive: true, isConstrained: false
        )
        XCTAssertNotEqual(fourG, fiveG)
        XCTAssertEqual(fiveG, NetworkPathStatus(
            connection: .cellular, cellularTechnology: .fiveGNSA, operatorName: "Orange",
            operatorMcc: 208, operatorMnc: 1, isExpensive: true, isConstrained: false))
    }

    /// `nil` et une valeur ne doivent jamais être confondus (perte de l'opérateur
    /// en entrant dans un tunnel, par exemple).
    func testNilAndValueAreDistinct() {
        let withoutOperator = NetworkPathStatus(
            connection: .cellular, cellularTechnology: .fourG, operatorName: nil,
            operatorMcc: nil, operatorMnc: nil, isExpensive: true, isConstrained: false
        )
        XCTAssertNotEqual(Self.reference, withoutOperator)
    }

    func testSimPlmnIsCarriedOnlyOnCellularPaths() {
        let simPlmn = "310001"
        let cellular = NetworkPathStatus.map(
            NetworkPathSnapshot(
                usesWiFi: false, usesCellular: true, usesWired: false,
                isExpensive: true, isConstrained: false
            ),
            operatorMcc: 310,
            operatorMnc: 1,
            simPlmn: simPlmn
        )
        let wifi = NetworkPathStatus.map(
            NetworkPathSnapshot(
                usesWiFi: true, usesCellular: false, usesWired: false,
                isExpensive: false, isConstrained: false
            ),
            operatorMcc: 310,
            operatorMnc: 1,
            simPlmn: simPlmn
        )

        XCTAssertEqual(cellular.simPlmn, simPlmn)
        XCTAssertNil(wifi.simPlmn)
    }
}
