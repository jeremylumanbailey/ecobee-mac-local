"""Synthetic pipe peer: never loads aiohomekit, Keychain, or network services."""
import json, sys, time
for line in sys.stdin:
    request = json.loads(line)
    command = request['command']
    response = {'id': request['id'], 'ok': True, 'result': {'echo': command}}
    if command == 'exit': sys.exit(2)
    if command == 'wait': time.sleep(30)
    if command == 'oversize':
        sys.stdout.write('x' * 4_000_001); sys.stdout.flush(); continue
    if command == 'error': response = {'id': request['id'], 'ok': False, 'error': 'Synthetic rejection'}
    if command == 'wrong-id':
        print(json.dumps({'id':'old-request','ok':True,'result':{'echo':'wrong'}}),flush=True)
    if command == 'malformed':
        print('not json',flush=True)
    data = json.dumps(response)+'\n'
    if command == 'fragmented':
        sys.stdout.write(data[:7]);sys.stdout.flush();time.sleep(.02);sys.stdout.write(data[7:]);sys.stdout.flush()
    else: print(data,end='',flush=True)
