import random
from chess import uci
from chess import Board
import subprocess
import platform
import numpy as np

IS_WINDOWS = 'windows' in platform.system().lower()

class RandomWalking:
    modified_file_name = ''
    # for clarity
    modified_engine = None
    info_handler_modified = None
    variables_count = 0
    variable_names = []
    best_values = []
    range = []  # [[min0,max0], [min1, max1], ...]

    def __init__(self):
        if IS_WINDOWS:
            self.modified_file_name = 'tune.exe'
        else:
            self.modified_file_name = './stockfish'
        self.detect_variable_names()
        self.open_engine_process()
        self.modified_engine.setoption({'Threads': '1'})

    def detect_variable_names(self):
        try:
            result = []
            p = subprocess.Popen([self.modified_file_name, 'uci'], stdout=subprocess.PIPE, universal_newlines=True)
            p.stdout.readline()
            while True:
                line = p.stdout.readline()
                if 'id name' in line:
                    break
                result.append(line.split(','))
            # TODO: Add exception handling logic here
        finally:
            # TODO: it's assigned?
            p.kill()
        # We have all variable names now
        self.variables_count = len(result)
        for i in range(self.variables_count):
            self.variable_names.append(result[i][0])
            self.best_values.append(float(result[i][1]))
            self.range.append([int(result[i][2]), int(result[i][3])])

    def open_engine_process(self):
        self.modified_engine = uci.popen_engine(self.modified_file_name)
        self.info_handler_modified = uci.InfoHandler()
        self.modified_engine.info_handlers.append(self.info_handler_modified)

    def __del__(self):
        self.modified_engine.terminate(async_callback=False)

    def run_engine(self, fen, max_depth=0, move_time=0):
        self.modified_engine.setoption({'Clear': 'Hash'})
        board = Board()
        board.set_fen(fen)
        self.modified_engine.position(board)
        if max_depth != 0:
            self.modified_engine.go(depth=max_depth, async_callback=False)
        else:
            self.modified_engine.go(movetime=move_time, async_callback=False)            
        while self.modified_engine.bestmove is None:
            pass
        result = self.info_handler_modified.info["score"][1].cp
        return result

    def mae(self, fen_file_path, max_samples):
        # FEN file format is: odd lines is FEN position even lines is ideal outputs
        fen_file = open(fen_file_path)
        s = 0.0
        count = 0
        fen_line = fen_file.readline()     # FEN position
        max_samples *= 1.0
        while fen_line != '' and count < max_samples:
            cp = int(fen_file.readline())     # ideal values in centipawn
            error = abs(self.run_engine(fen=fen_line, move_time=10) - cp)
            s += error
            count += 1
            fen_line = fen_file.readline()     # FEN position
        fen_file.close()
        return s

    def tune(self, fen_file_path, max_samples):
        values = []
        for i in range(self.variables_count):
            values.append(0.0)

        for i in range(self.variables_count):
            self.modified_engine.setoption({self.variable_names[i]: self.best_values[i]})
        self.modified_engine.ucinewgame(async_callback=False)
        min_error = error = self.mae(fen_file_path, max_samples)
        print('Error before first iteration: ' + error.__repr__())
        
        error_vector = []
        value_vector = []
        max_iterations = 500 # max_iterations > self.variables_count to avoid inf values
        for iteration in range(max_iterations):
            print('Iteration:' + iteration.__repr__())
            for i in range(self.variables_count):
                values[i] = random.randint(min(self.best_values)-3, max(self.best_values)+3)
                self.modified_engine.setoption({self.variable_names[i]: values[i]})
            self.modified_engine.ucinewgame(async_callback=False)
            error = self.mae(fen_file_path, max_samples)

            print('Error: ' + error.__repr__())
            if error == 0:
                break
            error_vector.append(float(error))
            value_vector.extend(values)
        
        # Binning, averaging and finding minima
        error_array = np.array(error_vector)
        value_array = np.array(value_vector).reshape(max_iterations, self.variables_count)
        bins = value_array.transpose()
        mean_array = []
        optimized = []
        for count in range(self.variables_count):
            mean_array.append([np.mean(error_array[np.where(bins[count]==i)]) for i in bins[count]])         
            optimized.append(bins[count][mean_array[count].index(min(mean_array[count]))])
        print(optimized)
        log_file = open('result.txt', 'a+')
        log_file.writelines(mean_array.__repr__() + '\n')
        log_file.writelines(bins.__repr__() + '\n')
        log_file.close()
        
def main():
    rw = RandomWalking()
    rw.tune("analyzed.txt", 100)  # FEN file and sample size

main()
