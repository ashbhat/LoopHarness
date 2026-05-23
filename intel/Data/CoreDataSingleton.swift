//
//  CoreDataSingleton.swift
//  Loop
//
//  Created by Ash Bhat on 11/2/24.
//

import Foundation

struct DriverIdInfo {
    var name: String
    var birth_date: String
    var address: String
    var drivers_id: String
    
    var dict: [String: Any] {
        return [
            "name": name,
            "birth_date": birth_date,
            "address": address,
            "drivers_id": drivers_id
        ]
    }
    
}

class CoreDataSingleton {
    static let shared = CoreDataSingleton()
    
    var driverIdInfo: DriverIdInfo? {
        get {
            
            let defaults = UserDefaults.standard
            let name = defaults.string(forKey: "name")
            let birth_date = defaults.string(forKey: "birth_date")
            let address = defaults.string(forKey: "address")
            let drivers_id = defaults.string(forKey: "drivers_id")
            
            if let name = name, let birth_date = birth_date, let address = address, let drivers_id = drivers_id {
                return DriverIdInfo(name: name, birth_date: birth_date, address: address, drivers_id: drivers_id)
            }
            return nil
        }
        
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue?.name, forKey: "name")
            defaults.set(newValue?.birth_date, forKey: "birth_date")
            defaults.set(newValue?.address, forKey: "address")
            defaults.set(newValue?.drivers_id, forKey: "drivers_id")
            defaults.synchronize()
        }
    }
}
