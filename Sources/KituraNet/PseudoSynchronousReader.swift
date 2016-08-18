/**
 * Copyright IBM Corporation 2016
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import Dispatch
import Foundation

import LoggerAPI
import Socket

/// The PseudoSynchronousReader class provides an "adapter" between the asynchronous
/// arival of data on the socket and the synchronous read APIs in the upper API layers.
/// Reads from this "adapter", read all available data in it's internal buffer.
///
/// To do this, this class maintains an internal data buffer, a lock, and a semaphore.
///
/// As both the addDataToRead and the read functions modify the internal data buffer (either
/// adding data to it or emptying it out), they both grab the bufferLock before modifying
/// the buffer. An optimization is performed in the addDataToRead, in that if the buffer is
/// empty the lock isn't acquired.
///
/// When the data buffer is empty the read function uses the readingSemaphore to wait, if
/// needed, for data to be added to the buffer.
///
/// **Note:** The Grand Central Dispatch DispatchSemaphore class can act as a classic
/// semaphore and as a lock.
class PseudoSynchronousReader {

    private let clientSocket: Socket
    
    private var noDataToRead = true
    private let buffer = NSMutableData()

    #if os(Linux)
        private let readingSemaphore: dispatch_semaphore_t
        private let bufferLock: dispatch_semaphore_t
    #else
        private let readingSemaphore = DispatchSemaphore(value: 0)
        private let bufferLock = DispatchSemaphore(value: 1)
    #endif
    
    var remoteHostname: String { return clientSocket.remoteHostname }
    
    init(clientSocket: Socket) {
        self.clientSocket = clientSocket
        
        #if os(Linux)
            readingSemaphore = dispatch_semaphore_create(0)
            bufferLock = dispatch_semaphore_create(1)
        #endif
    }
    
    /// Add data to the internal buffer to be read by the raed function
    ///
    /// - Parameter from: The NSData object containing the data to be added
    func addDataToRead(from: NSData) {
        let needToLock = buffer.length != 0
        if  needToLock {
            lockReadLock()
        }
        
        #if os(Linux)
            buffer.append(Data._unconditionallyBridgeFromObjectiveC(from))
        #else
            buffer.append(from as Data)
        #endif
        
        if  noDataToRead  {
            #if os(Linux)
                dispatch_semaphore_signal(readingSemaphore)
            #else
                readingSemaphore.signal()
            #endif
            noDataToRead = false
        }
        if  needToLock  {
            unlockReadLock()
        }
    }
    
    /// Read data from the buffer to the specified NSMutableData
    ///
    /// - Parameter into: The NSMutableData object to append the data in the buffer to.
    func read(into: NSMutableData) -> Int {
        if  noDataToRead  {
            #if os(Linux)
                dispatch_semaphore_wait(readingSemaphore, DISPATCH_TIME_FOREVER)
            #else
                _ = readingSemaphore.wait(timeout: DispatchTime.distantFuture)
            #endif
        }
        let result: Int
        if  buffer.length != 0  {
            lockReadLock()
            
            result = buffer.length
            #if os(Linux)
                into.append(Data._unconditionallyBridgeFromObjectiveC(buffer))
            #else
                into.append(buffer as Data)
            #endif
            
            buffer.length = 0
            noDataToRead = true
            
            unlockReadLock()
        }
        else {
            result = 0
        }
        
        return result
    }
    
    private func lockReadLock() {
        #if os(Linux)
            dispatch_semaphore_wait(bufferLock, DISPATCH_TIME_FOREVER)
        #else
            _ = bufferLock.wait(timeout: DispatchTime.distantFuture)
        #endif
    }
    
    private func unlockReadLock() {
        #if os(Linux)
            dispatch_semaphore_signal(bufferLock)
        #else
            bufferLock.signal()
        #endif
    }
}
