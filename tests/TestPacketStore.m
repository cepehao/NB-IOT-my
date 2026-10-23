classdef TestPacketStore < matlab.unittest.TestCase
 methods (Test)
  function wrapperRoundTrip(test)
   bits=int8(mod((1:1600)',2)); [b,m]=nbiot.traffic.segmentPacket(bits,uint16(31));
   test.verifyNumElements(b,8); test.verifyEqual(m.validPayloadBits,[208*ones(7,1);144]);
   test.verifyEqual(nbiot.traffic.reassemblePacket(b),bits);
   b{2}(17:24)=0; test.verifyError(@()nbiot.traffic.reassemblePacket(b),'nbiot:traffic:MalformedPacket');
  end
  function receiptKeepsQueueAndDeliveryIrreversible(test)
   c=nbiot.config.defaultConfig(); c.simulation.numUE=1; p=nbiot.traffic.PacketStore(c);
   for k=1:10, test.verifyTrue(p.enqueue(arrival(k))); end
   a=arrival(11); test.verifyFalse(p.enqueue(a)); test.verifyEqual(p.get(11).reason,'overflow');
   packet=p.get(1);
   for k=0:6, test.verifyFalse(p.markReceived(1,k,packet.blocks{k+1},10+k)); end
   test.verifyEqual(p.get(1).status,'pending'); test.verifyTrue(p.markReceived(1,7,packet.blocks{8},17));
   test.verifyFalse(p.markReceived(1,7,packet.blocks{8},18)); test.verifyEqual(p.queueLength(1),10);
   p.markTerminal(1,'dropped','confirmation_timeout',20); test.verifyEqual(p.get(1).status,'delivered');
   test.verifyEqual(p.queueLength(1),9); test.verifyEqual(p.head(1),uint32(2));
   p.finalize(100); test.verifyEqual(p.counters.created,p.counters.delivered+p.counters.dropped+p.counters.unfinished);
   test.verifyEqual(p.counters.deliveredPayloadBits,1600);
  end
  function malformedAndMissingFragment(test)
   c=nbiot.config.defaultConfig(); c.simulation.numUE=1; p=nbiot.traffic.PacketStore(c); p.enqueue(arrival(1)); q=p.get(1);
   b=q.blocks{1}; b(41)=1; test.verifyError(@()p.markReceived(1,0,b,1),'nbiot:traffic:MalformedPacket');
   for k=0:6, p.markReceived(1,k,q.blocks{k+1},k+1); end
   p.finalize(10); test.verifyEqual(p.get(1).status,'unfinished'); test.verifyEqual(p.counters.delivered,0);
  end
  function lifetimeAndConfirmedReceipt(test)
   c=nbiot.config.defaultConfig(); c.simulation.numUE=1; p=nbiot.traffic.PacketStore(c); p.enqueue(arrival(1)); p.enqueue(arrival(2)); q=p.get(1);
   for k=0:7, p.markReceived(1,k,q.blocks{k+1},k+1); end
   p.localFinish(1,9,true); test.verifyTrue(p.get(1).ueConfirmed); test.verifyEqual(p.head(1),uint32(2));
   test.verifyEmpty(p.expireLifetime(9999)); test.verifyEqual(p.expireLifetime(10000),uint32(2));
   test.verifyEqual(p.get(2).reason,'lifetime'); test.verifyEqual(p.get(1).status,'delivered');
  end
 end
end
function a=arrival(k)
a=struct('packetId',uint32(k),'ueId',uint32(1),'createdTick',uint64(0),'sequence',uint16(k),'payloadBits',zeros(1600,1,'int8'));
end
