from memory import memset_zero, memcpy
from memory.unsafe import Pointer
from memory import memset_zero, memcpy
from random import rand
from runtime.llcl import Runtime
from algorithm import vectorize, parallelize
from random import rand, random_si64, seed, randint
from math import sin, cos, log, sqrt, exp, min, max

from ..graph.tensor import Tensor
from ..operators.forward import mul, add, sum, conv_2d, relu, max_pool_2d, softmax, mse, ce, reshape, transpose, copy
from ..operators.backward import mul_grad, add_grad, conv_2d_grad, sum_grad, relu_grad, max_pool_2d_grad, softmax_grad, mse_grad, ce_grad, reshape_grad, transpose_grad, copy_grad
from ..helpers.shape import shape, Vec

alias nelts = simdwidthof[DType.float32]()

struct Module:
    var tensors: DynamicVector[Tensor]
    var counter: Int
    var forward_tape: DynamicVector[Int]
    var backward_tape: DynamicVector[Int]

    fn __init__(inout self):
        self.tensors = DynamicVector[Tensor](0)
        self.counter = 0
        self.forward_tape = DynamicVector[Int]()
        self.backward_tape = DynamicVector[Int]()

    @always_inline
    fn add_to_graph(inout self, inout a: Tensor):
        a.set_id(self.counter)
        a.in_tensors = True
        self.counter += 1
        self.tensors.push_back(a)

    @always_inline
    fn print_forward_tape(self):
        print_no_newline("[ ")
        let len = len(self.forward_tape)
        for i in range(len):
            print_no_newline(self.forward_tape[i])
            if (i < len-1):
                print_no_newline(", ")
        print_no_newline(" ]\n")
    
    @always_inline
    fn print_backward_tape(self):
        print_no_newline("[ ")
        let len = len(self.backward_tape)
        for i in range(len):
            print_no_newline(self.backward_tape[i])
            if (i < len-1):
                print_no_newline(", ")
        print_no_newline(" ]\n")

    @always_inline
    fn mul(inout self, inout a: Tensor, inout b: Tensor) -> Tensor:

        # # check dimensions
        let a_num_dims = a.num_dims
        let b_num_dims = b.num_dims
        if(a.shape[a_num_dims-1] != b.shape[b_num_dims-2]):
            print("Error (at mul): For Matrix Multiplication, Matrices need to in the following shape: c[mxn] = a[mxk] * b[kxn]")

        # init result Tensor 
        var new_shape = DynamicVector[Int](0)
        
        # regular
        if(a_num_dims == b_num_dims):
            for i in range(b_num_dims-1):
                new_shape.push_back(a.shape[i])
            new_shape.push_back(b.shape[b_num_dims-1])

        # broadcast a
        elif(b_num_dims > a_num_dims):
            for i in range(b_num_dims-2):
                new_shape.push_back(b.shape[i])
            new_shape.push_back(a.shape[a_num_dims-2])
            new_shape.push_back(b.shape[b_num_dims-1])

        # broadcast b 
        elif(a_num_dims > b_num_dims):
            for i in range(a_num_dims-1):
                new_shape.push_back(a.shape[i])
            new_shape.push_back(b.shape[b_num_dims-1])        

        var c = Tensor(new_shape)

        c.set_name('mul')

        if(not a.in_tensors):
            c.add_parent(self.counter)
            self.add_to_graph(a)
        else:
            c.add_parent(a.id)

        if(not b.in_tensors):
            c.add_parent(self.counter)
            self.add_to_graph(b)
        else:
            c.add_parent(b.id)
        self.add_to_graph(c)

        return c 
        
    @always_inline
    fn add(inout self, inout a: Tensor, inout b: Tensor) -> Tensor:

        let a_num_dims = a.num_dims
        let b_num_dims = b.num_dims
        # if(a.shape[a_num_dims-2] != b.shape[b_num_dims-2] or a.shape[a_num_dims-1] != b.shape[b_num_dims-1]):
        #     print("Error (at add): For Matrix addition, Matrices need to in the following shape: c[mxn] = a[mxn] + b[mxn]")

        # init result Tensor 
        var new_shape = DynamicVector[Int](0)
        
        # regular
        if(a_num_dims == b_num_dims):
            for i in range(b_num_dims):
                new_shape.push_back(a.shape[i])

        # broadcast a
        elif(b_num_dims > a_num_dims):
            for i in range(b_num_dims):
                new_shape.push_back(b.shape[i])

        # broadcast b 
        elif(a_num_dims > b_num_dims):
            for i in range(a_num_dims):
                new_shape.push_back(a.shape[i])  

        var c = Tensor(new_shape)

        c.set_name('add')

        if(not a.in_tensors):
            c.add_parent(self.counter)
            self.add_to_graph(a)
        else:
            c.add_parent(a.id)

        if(not b.in_tensors):
            c.add_parent(self.counter)
            self.add_to_graph(b)
        else:
            c.add_parent(b.id)
        self.add_to_graph(c)

        return c 

    @always_inline
    fn conv_2d(inout self, inout a: Tensor, inout b: Tensor, padding: Int, stride: Int) -> Tensor: # a: input, b: kernels

        # assumption: a (batch of input images) is of shape (batch_size, channels, width, height)
        #             b (set of kernels) is of shape (num_filters, channels, a, b)

        let a_num_dims = a.num_dims
        let b_num_dims = b.num_dims

        let batch_size = a.shape[0]
        let in_channels = a.shape[1]
        let width = a.shape[2]
        let height = a.shape[3]

        let out_channels = b.shape[0]
        if(in_channels != b.shape[1]):
            print("Error (at conv_2d): number of channels must be equal in the input and the kernels")
        let kernel_width = b.shape[2]
        let kernel_height = b.shape[3]

        # init result Tensor 
        let new_shape = shape(batch_size,out_channels, (width - kernel_width + 2*padding) // stride + 1, (height - kernel_height + 2*padding) // stride + 1) 
        var c = Tensor(new_shape)

        c.other_params.store(0, padding)
        c.other_params.store(1, stride)

        c.set_name('conv_2d')

        if(not a.in_tensors):
            c.add_parent(self.counter)
            self.add_to_graph(a)
        else:
            c.add_parent(a.id)

        if(not b.in_tensors):
            c.add_parent(self.counter)
            self.add_to_graph(b)
        else:
            c.add_parent(b.id)
        self.add_to_graph(c)

        return c 

    @always_inline
    fn relu(inout self, inout a: Tensor) -> Tensor: 
        var new_shape = DynamicVector[Int]()
        for i in range(a.num_dims):
            new_shape.push_back(a.shape[i])

        var b = Tensor(new_shape)

        b.set_name('relu')

        if(not a.in_tensors):
            b.add_parent(self.counter)
            self.add_to_graph(a)
        else:
            b.add_parent(a.id)
        self.add_to_graph(b)

        return b

    @always_inline
    fn max_pool_2d(inout self, inout a: Tensor, kernel_width: Int, kernel_height: Int, stride: Int, padding: Int) -> Tensor: 
        let new_shape = shape(a.shape[0],a.shape[1],(2*padding + a.shape[2] - (kernel_width - 1) - 1)//stride + 1, (2*padding + a.shape[3] - (kernel_height - 1) - 1)//stride + 1)

        var b = Tensor(new_shape)

        b.other_params.store(0,padding)
        b.other_params.store(1,stride)
        b.other_params.store(2,kernel_width)
        b.other_params.store(3,kernel_height)

        b.set_name('max_pool_2d')

        if(not a.in_tensors):
            b.add_parent(self.counter)
            self.add_to_graph(a)
        else:
            b.add_parent(a.id)
        self.add_to_graph(b)

        return b


    @always_inline
    fn sum(inout self, inout a: Tensor) -> Tensor: 

        var b = Tensor(shape(1,1))

        b.set_name('sum')

        if(not a.in_tensors):
            b.add_parent(self.counter)
            self.add_to_graph(a)
        else:
            b.add_parent(a.id)
        self.add_to_graph(b)

        return b

    @always_inline
    fn softmax(inout self, inout a: Tensor) -> Tensor: 

        var new_shape = DynamicVector[Int]()
        for i in range(a.num_dims):
            new_shape.push_back(a.shape[i])

        var b = Tensor(new_shape)

        b.set_name('softmax')

        if(not a.in_tensors):
            b.add_parent(self.counter)
            self.add_to_graph(a)
        else:
            b.add_parent(a.id)
        self.add_to_graph(b)

        return b

    @always_inline
    fn mse(inout self, inout a: Tensor, inout b: Tensor) -> Tensor:

        # check dimensions
        if(a.num_dims != b.num_dims):
            print("Error (at mse): number of dimensions are not equal")
        let num_dims = a.num_dims
        if(a.shape[num_dims-2] != b.shape[num_dims-2] or a.shape[num_dims-1] != b.shape[num_dims-1]):
            print("Error (at mse): For mse computation, Matrices need to in the following shape: c[mxn] = (a[mxn] - b[mxn])^2")

        # init result Tensor 
        var new_shape = DynamicVector[Int]()
        for i in range(num_dims):
            new_shape.push_back(a.shape[i])
        var c = Tensor(shape(1))

        c.set_name('mse')

        if(not a.in_tensors):
            c.add_parent(self.counter)
            self.add_to_graph(a)
        else:
            c.add_parent(a.id)

        if(not b.in_tensors):
            c.add_parent(self.counter)
            self.add_to_graph(b)
        else:
            c.add_parent(b.id)
        self.add_to_graph(c)

        return c 

    @always_inline
    fn ce(inout self, inout a: Tensor, inout b: Tensor) -> Tensor:

        # check dimensions
        if(a.num_dims != b.num_dims):
            print("Error (at ce): number of dimensions are not equal")
        let num_dims = a.num_dims
        if(a.shape[num_dims-2] != b.shape[num_dims-2] or a.shape[num_dims-1] != b.shape[num_dims-1]):
            print("Error (at ce): For ce computation, Matrices need to in the following shape: c[mxn] = op(a[mxn],b[mxn])")

        # init result Tensor 
        var new_shape = DynamicVector[Int]()
        for i in range(num_dims):
            new_shape.push_back(a.shape[i])
        var c = Tensor(shape(1))

        c.set_name('ce')
        if(a.name == "softmax"):
            a.other_params.store(0,3001) # 3001 means that the child is ce node -> simplifies grad computation
        if(b.name == "softmax"):
            b.other_params.store(0,3001)

        if(not a.in_tensors):
            c.add_parent(self.counter)
            self.add_to_graph(a)
        else:
            c.add_parent(a.id)

        if(not b.in_tensors):
            c.add_parent(self.counter)
            self.add_to_graph(b)
        else:
            c.add_parent(b.id)
        self.add_to_graph(c)

        return c 

    @always_inline
    fn reshape(inout self, inout a: Tensor, newShape: DynamicVector[Int]) -> Tensor: # also braodcastv
        let num_dims = len(newShape)
        var new_shape = DynamicVector[Int]()
        for i in range(num_dims):
            new_shape.push_back(newShape[i])

        var b = Tensor(new_shape)

        if(b.cap % a.cap != 0):
            print("Error (at reshape): b.cap % a.cap == 0 and b.cap // a.cap >= 1 is not fulfilled")

        b.set_name('reshape')

        if(not a.in_tensors):
            b.add_parent(self.counter)
            self.add_to_graph(a)
        else:
            b.add_parent(a.id)
        self.add_to_graph(b)

        return b

    @always_inline
    fn transpose(inout self, inout a: Tensor) -> Tensor: 
        let num_dims = a.num_dims
        if(num_dims < 2):
            print("Error (at transpose): a transposed Tensor need to heave at least two dimenions!")

        var new_shape = DynamicVector[Int]()
        for i in range(num_dims - 2):
            new_shape.push_back(a.shape[i])
        new_shape.push_back(a.shape[num_dims-1])
        new_shape.push_back(a.shape[num_dims-2])

        var b = Tensor(new_shape)

        b.set_name('transpose')

        if(not a.in_tensors):
            b.add_parent(self.counter)
            self.add_to_graph(a)
        else:
            b.add_parent(a.id)
        self.add_to_graph(b)

        return b

    @always_inline
    fn copy(inout self, inout a: Tensor) -> Tensor: 

        var new_shape = DynamicVector[Int]()
        for i in range(a.num_dims):
            new_shape.push_back(a.shape[i])

        var b = Tensor(new_shape)

        b.set_name('copy')

        if(not a.in_tensors):
            b.add_parent(self.counter)
            self.add_to_graph(a)
        else:
            b.add_parent(a.id)
        self.add_to_graph(b)

        return b

    fn top_order(inout self, inout Tensor: Tensor):  
        if not Tensor.visited:
            for i in range(Tensor.num_parents):
                let nextTensorId = Tensor.get_parent(i)
                var nextTensor = self.tensors[nextTensorId]
                self.top_order(nextTensor)
            self.forward_tape.push_back(Tensor.id)
            Tensor.visited = True

    @always_inline
    fn forward(inout self, inout computingTensor: Tensor):
        for i in range(self.counter):
            self.tensors[i].set_visited(False)
            if(self.tensors[i].name != 'none'):
                self.tensors[i].fill(0)
        self.forward_tape = DynamicVector[Int]()
        self.top_order(computingTensor)

        for i in range(self.counter):
            var curr = self.tensors[i]
            if(curr.name == 'mul'):
                let par1 = self.tensors[curr.get_parent(0)]
                let par2 = self.tensors[curr.get_parent(1)]
                mul(curr,par1,par2)
            if(curr.name == 'add'):
                let par1 = self.tensors[curr.get_parent(0)]
                let par2 = self.tensors[curr.get_parent(1)]
                add(curr,par1,par2)
            if(curr.name == 'conv_2d'):
                let par1 = self.tensors[curr.get_parent(0)]
                let par2 = self.tensors[curr.get_parent(1)]
                conv_2d(curr,par1,par2)
            if(curr.name == 'relu'):
                let par1 = self.tensors[curr.get_parent(0)]
                relu(curr,par1) 
            if(curr.name == 'max_pool_2d'):
                let par1 = self.tensors[curr.get_parent(0)]
                max_pool_2d(curr,par1) 
            if(curr.name == 'sum'):
                let par1 = self.tensors[curr.get_parent(0)]
                sum(curr,par1)
            if(curr.name == 'softmax'):
                let par1 = self.tensors[curr.get_parent(0)]
                softmax(curr,par1)
            if(curr.name == 'mse'):
                let par1 = self.tensors[curr.get_parent(0)]
                let par2 = self.tensors[curr.get_parent(1)]
                mse(curr,par1,par2) 
            if(curr.name == 'ce'):
                let par1 = self.tensors[curr.get_parent(0)]
                let par2 = self.tensors[curr.get_parent(1)]
                ce(curr,par1,par2) 
            if(curr.name == 'reshape'):
                let par1 = self.tensors[curr.get_parent(0)]
                reshape(curr,par1)
            if(curr.name == 'transpose'):
                let par1 = self.tensors[curr.get_parent(0)]
                transpose(curr,par1)
            if(curr.name == 'copy'):
                let par1 = self.tensors[curr.get_parent(0)]
                copy(curr,par1)

    fn backward_order(inout self, Tensor: Tensor):
        self.backward_tape = DynamicVector[Int](0)
        self.backward_tape.push_back(Tensor.id)
        var it = 0
        while(it < len(self.backward_tape)):
            let currId = self.backward_tape[it]
            let curr = self.tensors[currId]
            for i in range(curr.num_parents):
                let parId = curr.get_parent(i)
                let par = self.tensors[parId]
                if(par.requires_grad):
                    self.backward_tape.push_back(parId)
            it += 1

    @always_inline
    fn backward(inout self, inout lastTensor: Tensor):
        if(lastTensor.cap != 1):
            print("Error: Gradient can be implicitly created only for scalar outputs")
            return
        self.backward_order(lastTensor)
        for i in range(self.counter):
            if(self.tensors[i].requires_grad):
                self.tensors[i].fill_grad(0)

        for i in range(len(self.backward_tape)):
            let currId = self.backward_tape[i]
            let curr = self.tensors[currId]
            if(curr.name == 'mul'):
                var par1 = self.tensors[curr.get_parent(0)]
                var par2 = self.tensors[curr.get_parent(1)]
                mul_grad(curr,par1,par2)
            if(curr.name == 'add'):
                var par1 = self.tensors[curr.get_parent(0)]
                var par2 = self.tensors[curr.get_parent(1)]
                add_grad(curr,par1,par2)
            if(curr.name == 'conv_2d'):
                var par1 = self.tensors[curr.get_parent(0)]
                var par2 = self.tensors[curr.get_parent(1)]
                conv_2d_grad(curr,par1,par2)
            if(curr.name == 'relu'):
                var par1 = self.tensors[curr.get_parent(0)]
                relu_grad(curr,par1)
            if(curr.name == 'max_pool_2d'):
                var par1 = self.tensors[curr.get_parent(0)]
                max_pool_2d_grad(curr,par1)
            if(curr.name == 'sum'):
                var par1 = self.tensors[curr.get_parent(0)]
                sum_grad(curr,par1)
            if(curr.name == 'softmax'):
                var par1 = self.tensors[curr.get_parent(0)]
                softmax_grad(curr,par1)
            if(curr.name == 'mse'):
                var par1 = self.tensors[curr.get_parent(0)]
                var par2 = self.tensors[curr.get_parent(1)]
                mse_grad(curr,par1,par2)
            if(curr.name == 'ce'):
                var par1 = self.tensors[curr.get_parent(0)]
                var par2 = self.tensors[curr.get_parent(1)]
                ce_grad(curr,par1,par2)
            if(curr.name == 'reshape'):
                var par1 = self.tensors[curr.get_parent(0)]
                reshape_grad(curr,par1)
            if(curr.name == 'transpose'):
                var par1 = self.tensors[curr.get_parent(0)]
                transpose_grad(curr,par1)
            if(curr.name == 'copy'):
                var par1 = self.tensors[curr.get_parent(0)]
                copy_grad(curr,par1)


    fn optimize(inout self, optType: String, lr: Float32 = 0.001, momentum: Float32 = 0.9, weight_decay: Float32 = 0.001, threshold: Float32 = Float32(100.0)):
        
        if(optType == "sgd"):
            for i in range(len(self.backward_tape)):
                let id = self.tensors[self.backward_tape[i]].id
                for index in range(self.tensors[id].cap):
                    self.tensors[id].set_data(index, (1 - lr * weight_decay) * self.tensors[id].data.load(index) - lr * min(threshold,max(-threshold,self.tensors[id].grad.load(index))))
                @parameter
                fn v_update_data_sgd[nelts: Int](index: Int):
                    self.tensors[id].data.simd_store[nelts](
                        index, (1 - lr * weight_decay) * self.tensors[id].data.simd_load[nelts](index) - lr * self.tensors[id].grad.simd_load[nelts](index)
                    )
                vectorize[nelts, v_update_data_sgd](self.tensors[id].cap)
        
        if(optType == "sgd_momentum"):
            for i in range(len(self.backward_tape)):
                let id = self.tensors[self.backward_tape[i]].id

                @parameter
                fn v_set_velocity[nelts: Int](index: Int):
                    self.tensors[id].velocity.simd_store[nelts](
                        index, momentum * self.tensors[id].velocity.simd_load[nelts](index) + lr * self.tensors[id].grad.simd_load[nelts](index)
                    )
                vectorize[nelts, v_set_velocity](self.tensors[id].cap)

                @parameter
                fn v_update_data_sgdPlus[nelts: Int](index: Int):
                    self.tensors[id].data.simd_store[nelts](
                        index, (1 - lr * weight_decay) * self.tensors[id].data.simd_load[nelts](index) - self.tensors[id].velocity.simd_load[nelts](index)
                    )
                vectorize[nelts, v_update_data_sgdPlus](self.tensors[id].cap)


    @always_inline
    fn print_graph(self): 
        print("Printing all tensors of the computational Graph .....\n")
        for i in range(self.counter):
            let n = self.tensors[i]
            print("Tensor ID: ", n.id, ", Name: ", n.name, ", rquiresGrad: ", n.requires_grad, ", cap = ", n.cap)
            n.print_data()
            n.print_grad()
        print("End of Printing all tensors of the computational Graph.")
