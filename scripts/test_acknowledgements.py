import json
import hashlib
from pathlib import Path
import tempfile
import unittest
from acknowledgements import generate


class CatalogueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'checkout'
        self.source.mkdir()
        (self.source / 'LICENSE').write_bytes(b'Original copyright\nPermission text\n')
        self.resolved = self.root / 'Package.resolved'
        self.pin = {'identity': 'example', 'location': 'https://example.org/library',
                    'state': {'version': '1.0', 'revision': 'abc'}}
        self.node = {'identity': 'example', 'name': 'Example', 'url': self.pin['location'],
                     'version': '1.0', 'path': str(self.source), 'dependencies': []}
        self.graph = {'dependencies': [self.node]}
        self.artifacts = self.root / 'artifacts'
        self.output = self.root / 'output'

    def run_generator(self):
        self.resolved.write_text(json.dumps({'pins': [self.pin]}))
        generate(self.resolved, self.graph, self.artifacts, self.output)
        return json.loads((self.output / 'index.json').read_text())

    def test_exact_text_nested_binary_notices_and_determinism(self):
        nested = self.source / 'vendor'; nested.mkdir()
        (nested / 'COPYING.txt').write_text('Nested licence\n')
        binary = self.artifacts / 'example' / 'framework'; binary.mkdir(parents=True)
        (binary / 'NOTICE').write_text('Binary notice\n')
        result = self.run_generator()
        self.assertEqual(len(result['packages'][0]['documents']), 3)
        self.assertEqual((self.output / 'example/source/LICENSE').read_bytes(), (self.source / 'LICENSE').read_bytes())
        before = (self.output / 'index.json').read_bytes()
        self.run_generator()
        self.assertEqual(before, (self.output / 'index.json').read_bytes())
        self.assertNotIn(str(self.root), before.decode())

    def test_add_remove_version_change_and_stale_files(self):
        self.run_generator()
        (self.output / 'obsolete').write_text('old')
        self.pin['state']['version'] = '2.0'; self.node['version'] = '2.0'
        result = self.run_generator()
        self.assertEqual(result['packages'][0]['version'], '2.0')
        self.assertFalse((self.output / 'obsolete').exists())
        # An unreferenced cached checkout does not enter the catalogue.
        stale = self.root / 'unused'; stale.mkdir(); (stale / 'LICENSE').write_text('unused')
        extra = dict(self.pin, identity='other')
        self.resolved.write_text(json.dumps({'pins': [self.pin, extra]}))
        self.graph['dependencies'].append(dict(self.node, identity='other'))
        generate(self.resolved, self.graph, self.artifacts, self.output)
        self.assertEqual(len(json.loads((self.output / 'index.json').read_text())['packages']), 2)
        self.graph['dependencies'].pop()
        self.assertEqual(len(self.run_generator()['packages']), 1)
        self.assertFalse((self.output / 'other').exists())

    def test_no_resolved_file_means_no_dependencies(self):
        self.run_generator()
        self.resolved.unlink()
        generate(self.resolved, {'dependencies': []}, self.artifacts, self.output)
        self.assertEqual(json.loads((self.output / 'index.json').read_text())['packages'], [])
        self.assertFalse((self.output / 'example').exists())
        with self.assertRaises(ValueError):
            generate(self.resolved, self.graph, self.artifacts, self.output)

    def test_missing_notices_or_checkout_fail(self):
        (self.source / 'LICENSE').unlink()
        with self.assertRaises(ValueError): self.run_generator()
        self.source.rmdir()
        with self.assertRaises(FileNotFoundError): self.run_generator()

    def test_symlink_escape_and_invalid_identity_fail(self):
        outside = self.root / 'outside'; outside.write_text('outside')
        (self.source / 'COPYING').symlink_to(outside)
        with self.assertRaises(ValueError): self.run_generator()
        (self.source / 'COPYING').unlink()
        self.pin['identity'] = '../escape'; self.node['identity'] = '../escape'
        with self.assertRaises(ValueError): self.run_generator()

    def test_graph_mismatch_and_version_mismatch_fail(self):
        self.node['version'] = '3.0'
        with self.assertRaises(ValueError): self.run_generator()
        self.node['version'] = '1.0'; self.graph['dependencies'] = []
        with self.assertRaises(ValueError): self.run_generator()

    def test_nontext_notice_fails_without_replacing_previous_catalogue(self):
        self.run_generator()
        previous = (self.output / 'index.json').read_bytes()
        (self.source / 'LICENSE').write_bytes(b'\xff\xfe')
        with self.assertRaises(UnicodeDecodeError): self.run_generator()
        self.assertEqual(previous, (self.output / 'index.json').read_bytes())

    def test_supplement_integrity_revision_and_dependency_removal(self):
        self.run_generator()
        text = self.root / 'GPL.txt'; text.write_text('Full additional original\n')
        config = self.root / 'notices.json'
        value = {'example': {'revision': 'abc', 'documents': [
            {'path': 'GPL.txt', 'sha256': hashlib.sha256(text.read_bytes()).hexdigest()}]}}
        config.write_text(json.dumps(value))
        generate(self.resolved, self.graph, self.artifacts, self.output, config)
        self.assertEqual((self.output / 'example/supplement/GPL.txt').read_bytes(), text.read_bytes())
        previous = (self.output / 'index.json').read_bytes()
        text.write_text('Truncated or replaced text')
        with self.assertRaises(ValueError):
            generate(self.resolved, self.graph, self.artifacts, self.output, config)
        self.assertEqual(previous, (self.output / 'index.json').read_bytes())
        text.unlink()
        with self.assertRaises(FileNotFoundError):
            generate(self.resolved, self.graph, self.artifacts, self.output, config)
        value['example']['revision'] = 'wrong'; config.write_text(json.dumps(value))
        with self.assertRaises(ValueError):
            generate(self.resolved, self.graph, self.artifacts, self.output, config)
        self.resolved.write_text(json.dumps({'pins': []}))
        generate(self.resolved, {'dependencies': []}, self.artifacts, self.output, config)
        self.assertFalse((self.output / 'example').exists())

    def test_supplement_cannot_read_outside_its_directory(self):
        self.run_generator()
        directory = self.root / 'supplements'; directory.mkdir()
        outside = self.root / 'outside'; outside.write_text('outside')
        (directory / 'GPL').symlink_to(outside)
        config = directory / 'notices.json'
        for path in ['../outside', 'GPL', str(outside)]:
            config.write_text(json.dumps({'example': {'revision': 'abc', 'documents': [
                {'path': path, 'sha256': hashlib.sha256(outside.read_bytes()).hexdigest()}]}}))
            with self.assertRaises(ValueError):
                generate(self.resolved, self.graph, self.artifacts, self.output, config)


if __name__ == '__main__':
    unittest.main()
